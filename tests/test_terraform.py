"""Terraform, offline: format, validate and `terraform test` (mock provider) for every stack, through the same script
the pull request's `terraform-checks` job runs. Plus the static facts about lock files and tfvars."""

from __future__ import annotations

import re
import shutil

import pytest

from conftest import ENVIRONMENTS, GENERATED_DIRS, ROOT, repo_files, run

needs_terraform = pytest.mark.skipif(shutil.which("terraform") is None, reason="terraform not installed")


@pytest.mark.terraform
@needs_terraform
@pytest.mark.parametrize("stack", ["bootstrap", "shared", "envs"])
def test_fmt_validate_and_terraform_test(stack):
    import os
    done = run(["bash", str(ROOT / "scripts" / "tf_checks.sh"), stack], dict(os.environ))
    if "Failed to install provider" in done.stdout + done.stderr or "Could not retrieve the list of available versions" in done.stdout + done.stderr:
        pytest.skip("the AWS provider is neither in the plugin cache nor downloadable here")
    assert done.returncode == 0, done.stdout[-3000:] + done.stderr[-2000:]
    assert "0 failed" in done.stdout


@pytest.mark.parametrize("stack", ["bootstrap", "shared", "envs"])
def test_lock_file_pins_the_provider_for_five_platforms(stack):
    lock = (ROOT / stack / ".terraform.lock.hcl").read_text(encoding="utf-8")
    assert 'version     = "6.68' in lock and 'constraints = "~> 6.68"' in lock
    assert len(set(re.findall(r'"h1:[^"]+"', lock))) >= 5, f"{stack}: lock file needs h1 hashes for five platforms"


def test_all_three_stacks_use_the_same_lock_file():
    locks = {(ROOT / s / ".terraform.lock.hcl").read_text(encoding="utf-8") for s in ("bootstrap", "shared", "envs")}
    assert len(locks) == 1


@pytest.mark.parametrize("stack", ["bootstrap", "shared", "envs"])
def test_version_constraints(stack):
    text = (ROOT / stack / "versions.tf").read_text(encoding="utf-8")
    assert 'required_version = ">= 1.15"' in text and 'version = "~> 6.68"' in text


def test_bootstrap_keeps_local_state_and_the_pipeline_stacks_use_s3():
    assert not (ROOT / "bootstrap" / "backend.tf").exists()
    for stack in ("shared", "envs"):
        assert 'backend "s3" {}' in (ROOT / stack / "backend.tf").read_text(encoding="utf-8")


def tfvars(path):
    values = {}
    for line in path.read_text().splitlines():
        m = re.match(r'^\s*(\w+)\s*=\s*"?([^"#\n]*?)"?\s*(#.*)?$', line)
        if m and not line.lstrip().startswith("#"):
            values[m.group(1)] = m.group(2)
    return values


# CloudWatch Logs accepts only these retention periods (days). A value outside the list fails at apply time, not at plan time.
CLOUDWATCH_RETENTION_DAYS = {1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653}
COMPUTE = {"dev": "lambda", "sit": "lambda", "pre-prod": "ecs", "prod": "ecs"}


@pytest.mark.parametrize("env", ENVIRONMENTS)
def test_each_environment_has_its_tfvars(env):
    """The CONTRACT of an environment's tfvars, not today's numbers: a pull request that changes a log retention (lab 3 of
    the course: dev 7 -> 14) or any other tunable must stay green. What is pinned is what the design promises."""
    values = tfvars(ROOT / "envs" / f"{env}.tfvars")
    assert set(values) == {"env", "compute", "log_retention_days", "bucket_versioning"}, "the four variables every environment sets"
    assert values["env"] == env, "the file's env is its name (the workspace guard compares them)"
    assert values["compute"] == COMPUTE[env], f"{env} runs on {COMPUTE[env]} (dev and sit: Lambda; pre-prod and prod: ECS Express)"
    assert values["log_retention_days"].isdigit() and int(values["log_retention_days"]) in CLOUDWATCH_RETENTION_DAYS, \
        f"log_retention_days must be one of CloudWatch's allowed values, not {values['log_retention_days']!r}"
    assert values["bucket_versioning"] in ("true", "false")
    if env in ("pre-prod", "prod"):
        assert values["bucket_versioning"] == "true", f"{env} keeps every object version"


def test_every_environment_has_a_test_file_and_there_is_a_guard_test():
    for env in ENVIRONMENTS:
        assert (ROOT / "envs" / "tests" / f"{env}.tftest.hcl").exists()
    assert (ROOT / "envs" / "tests" / "guard.tftest.hcl").exists()


def test_the_pointers_ignore_changes_to_their_value():
    text = (ROOT / "envs" / "ssm.tf").read_text(encoding="utf-8")
    for resource in ("model_pointer", "index_pointer"):
        block = text[text.index(f'resource "aws_ssm_parameter" "{resource}"'):]
        block = block[:block.index("\n}\n")]
        assert "ignore_changes = [value]" in block
    assert 'default     = "{\\"version\\": null}"' in (ROOT / "envs" / "variables.tf").read_text(encoding="utf-8")
    assert "OWNED" in text                                                      # the comment that tells students who owns them


def test_the_workspace_guard_is_a_precondition_not_a_check():
    text = (ROOT / "envs" / "main.tf").read_text(encoding="utf-8")
    assert "precondition" in text and "terraform.workspace == var.env" in text
    assert re.search(r'^check "', text, re.M) is None


ACCOUNT_ID = re.compile(r"(?<!\d)\d{12}(?!\d)")
LONG_HEX = re.compile(r"[0-9a-f]{32,}")             # the lock files' zh: hashes are 64 hex digits: 12 digits in a row can occur inside one


def leaks(root=ROOT):
    """(file, what) for every committed 12-digit number outside tests/ and every key-like string."""
    found = []
    for path in repo_files(root):
        text = path.read_text(encoding="utf-8", errors="ignore")
        rel = path.relative_to(root)
        if "tests" not in rel.parts and ACCOUNT_ID.search(LONG_HEX.sub("", text)):
            found.append((rel.as_posix(), "a 12-digit number outside tests/"))
        if "AK" "IA" in text or "BEGIN PRIVATE" " KEY" in text:
            found.append((rel.as_posix(), "a key-like string"))
    return found


def test_no_account_id_or_secret_is_committed():
    """A 12-digit number may appear only in tests, as the made-up account of the mock provider. Only files git tracks (or would)
    are scanned: not .git/, .terraform/, .venv/ or caches, which a CI runner or a laptop fills with files that are not ours."""
    assert leaks() == []


def test_the_secret_scan_ignores_generated_folders_but_still_sees_a_leak(tmp_path):
    for folder in sorted(GENERATED_DIRS):
        (tmp_path / folder).mkdir()
        (tmp_path / folder / "FETCH_HEAD").write_text("123456789012\n")      # what a runner's .git really holds
    (tmp_path / "tests").mkdir()
    (tmp_path / "tests" / "test_x.py").write_text('ACCOUNT = "123456789012"\n')
    (tmp_path / "ok.md").write_text("nothing here\n")
    (tmp_path / "lock.hcl").write_text('hashes = ["zh:ab123456789012cd' + "e" * 48 + '"]\n')                    # 12 digits inside a hash
    (tmp_path / "other-repo" / ".git").mkdir(parents=True)                       # another repository checked out into a subfolder
    (tmp_path / "other-repo" / "fakes.py").write_text('ACCOUNT = "123456789012"\n')
    assert leaks(tmp_path) == []
    assert sorted(p.name for p in repo_files(tmp_path)) == ["lock.hcl", "ok.md", "test_x.py"]
    (tmp_path / "envs").mkdir()
    (tmp_path / "envs" / "dev.tfvars").write_text('role = "arn:aws:iam::123456789012:role/x"\n')
    assert leaks(tmp_path) == [("envs/dev.tfvars", "a 12-digit number outside tests/")]


def test_a_live_bootstrap_folder_does_not_trip_the_secret_scan(tmp_path):
    """The instructor's `terraform apply` leaves terraform.tfstate (account id inside) and a saved `plan` next to the code. Both are
    git-ignored; the scan skips them as git would."""
    (tmp_path / "bootstrap").mkdir()
    (tmp_path / "bootstrap" / "terraform.tfstate").write_text('{"account": "123456789012"}\n')
    (tmp_path / "bootstrap" / "terraform.tfstate.backup").write_text('{"account": "123456789012"}\n')
    (tmp_path / "bootstrap" / "plan").write_text("123456789012\n")
    (tmp_path / "bootstrap" / "main.tf").write_text("# nothing\n")
    assert leaks(tmp_path) == []
    assert [p.name for p in repo_files(tmp_path)] == ["main.tf"]
    (tmp_path / "bootstrap" / "notes.tf").write_text('x = "123456789012"\n')                  # a real leak is still found
    assert leaks(tmp_path) == [("bootstrap/notes.tf", "a 12-digit number outside tests/")]


def test_tf_checks_copies_no_state_plan_or_env_file():
    """scripts/tf_checks.sh works in a temp copy of the repository. It must leave out everything a real apply produces."""
    text = (ROOT / "scripts" / "tf_checks.sh").read_text(encoding="utf-8")
    tar = next(line for line in text.splitlines() if "tar cf -" in line)
    for pattern in ("--exclude .terraform", "--exclude '*.tfstate'", "--exclude '*.tfstate.*'", "--exclude plan", "--exclude tfplan", "--exclude '.env'"):
        assert pattern in tar, pattern


def test_the_names_in_bootstrap_are_the_names_shared_and_envs_create():
    """bootstrap/ builds roles that name resources before they exist; these are the strings both sides must agree on."""
    boot = (ROOT / "bootstrap" / "main.tf").read_text(encoding="utf-8")
    shared = (ROOT / "shared" / "main.tf").read_text(encoding="utf-8")
    for local, value in {
        "train_pipeline": '"${var.project}-train"', "monitor_pipeline": '"${var.project}-monitor"',
        "feature_group": '"${var.project}-transactions"', "glue_database": '"${var.project}_ml"',
    }.items():
        assert re.search(rf"^\s*{local}\s*=\s*{re.escape(value)}", boot, re.M), f"bootstrap {local}"
        assert re.search(rf"^\s*{local}\s*=\s*{re.escape(value)}", shared, re.M), f"shared {local}"
    assert re.search(r"athena_workgroup\s*=\s*var\.project", boot) and re.search(r"workgroup\s*=\s*var\.project", shared)
    for role in ("mlflow", "scheduler", "events", "studio"):
        assert f'"${{var.project}}-{role}"' in boot
        assert f'"${{var.project}}-{role}"' in "".join((ROOT / "shared" / f).read_text(encoding="utf-8") for f in ("mlflow.tf", "automation.tf", "studio.tf"))


def test_the_alarm_names_envs_creates_are_the_ones_the_promote_roles_may_read():
    """finrisk-ml's blue/green update names finrisk-<env>-endpoint-5xx and -latency; the promote role may DescribeAlarms exactly
    finrisk-<env>-endpoint-*; the retrain-on-drift rule matches finrisk-prod-model-*; envs/ creates the three prod alarms with that prefix."""
    alarms = (ROOT / "envs" / "alarms.tf").read_text(encoding="utf-8")
    assert '"5xx" = {' in alarms and '"latency" = {' in alarms and '"${local.name}-endpoint-${each.key}"' in alarms
    for suffix in ("model-drift", "model-prior-shift", "model-quality"):
        assert f'"${{local.name}}-{suffix}"' in alarms
    roles = (ROOT / "bootstrap" / "roles_ml.tf").read_text(encoding="utf-8")
    assert 'alarm:${var.project}-${e}-endpoint-*' in roles
    assert 'alarm:${var.project}-prod-model-*' in roles
    rule = (ROOT / "shared" / "automation.tf").read_text(encoding="utf-8")
    assert 'prefix = "${var.project}-prod-model-"' in rule


def test_the_ml_bucket_lifecycle_has_no_rule_for_the_keep_forever_folders():
    text = (ROOT / "shared" / "ml.tf").read_text(encoding="utf-8")
    block = text[text.index("expiring_prefixes"):]
    block = block[:block.index("]")]
    listed = set(re.findall(r'"([a-z-]+)"', block))
    assert listed == {"data", "datasets", "models", "metrics", "monitoring", "capture", "athena", "mlflow"}
    assert not listed & {"raw", "labels", "feature-store", "replay"}


def test_the_hourly_monitor_is_off_unless_asked():
    text = (ROOT / "shared" / "variables.tf").read_text(encoding="utf-8")
    block = text[text.index('variable "monitor_schedule_enabled"'):]
    block = block[:block.index("\n}\n")]
    assert "default     = false" in block
    assert 'state       = var.monitor_schedule_enabled ? "ENABLED" : "DISABLED"' in (ROOT / "shared" / "automation.tf").read_text(encoding="utf-8")


def test_the_studio_domain_deletes_its_file_system_and_is_optional():
    text = (ROOT / "shared" / "studio.tf").read_text(encoding="utf-8")
    assert 'home_efs_file_system = "Delete"' in text
    assert "var.create_studio_domain" in text
    assert 'default     = true' in (ROOT / "shared" / "variables.tf").read_text(encoding="utf-8").split('variable "create_studio_domain"')[1].split("}\n")[0]


def test_the_endpoint_role_parameter_is_published_for_every_environment():
    text = (ROOT / "envs" / "ssm.tf").read_text(encoding="utf-8")
    assert "endpoint_role_arn = aws_iam_role.endpoint.arn" in text
    # ... and the two pointers still keep their value out of Terraform's hands
    assert text.count("\n    ignore_changes = [value]\n") == 2

"""Terraform, offline: format, validate and `terraform test` (mock provider) for every stack, through the same script
the pull request's `terraform-checks` job runs. Plus the static facts about lock files and tfvars."""

from __future__ import annotations

import re
import shutil

import pytest

from conftest import ENVIRONMENTS, ROOT, run

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


@pytest.mark.parametrize("env,compute,days,versioning", [("dev", "lambda", "7", "false"), ("sit", "lambda", "14", "false"), ("pre-prod", "ecs", "30", "true"), ("prod", "ecs", "90", "true")])
def test_each_environment_has_its_tfvars(env, compute, days, versioning):
    assert tfvars(ROOT / "envs" / f"{env}.tfvars") == {"env": env, "compute": compute, "log_retention_days": days, "bucket_versioning": versioning}


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


def test_no_account_id_or_secret_is_committed():
    """A 12-digit number may appear only in tests, as the made-up account of the mock provider."""
    for path in ROOT.rglob("*"):
        if not path.is_file() or any(p in path.parts for p in (".terraform", "__pycache__", ".pytest_cache")) or path.suffix == ".pyc":
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        in_tests = "tests" in path.relative_to(ROOT).parts
        for number in re.findall(r"(?<!\d)\d{12}(?!\d)", text):
            assert in_tests, f"{path}: a 12-digit number outside tests/"
        assert "AK" "IA" not in text and "BEGIN PRIVATE" " KEY" not in text, path

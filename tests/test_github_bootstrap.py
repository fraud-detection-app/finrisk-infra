"""scripts/github_bootstrap.sh -- with a fake `gh` and a fake `terraform`: nothing leaves this machine."""

from __future__ import annotations

import json
import re
import subprocess

import pytest

from conftest import ENVIRONMENTS, FAKE_ACCOUNT, ORG, REPOS, ROOT, read_log, run

SCRIPT = ROOT / "scripts" / "github_bootstrap.sh"

CHECKS = {"infra": ["plan", "terraform-checks"], "app": ["test", "terraform"], "ml": ["test"], "knowledge": ["kb-check"]}
ENV_NAMES = {
    "infra": ["infra-shared", "infra-dev", "infra-sit", "infra-pre-prod", "infra-prod"],
    "app": ENVIRONMENTS, "knowledge": ENVIRONMENTS,
    "ml": ["ml", "model-approval", "simulation", *ENVIRONMENTS],
}
REVIEWERS = {
    "infra": {"infra-shared", "infra-pre-prod", "infra-prod"},
    "app": {"pre-prod", "prod"}, "knowledge": {"pre-prod", "prod"}, "ml": {"model-approval", "pre-prod", "prod"},
}


def script(*args: str, env: dict, outputs: str | None = None):
    cmd = ["bash", str(SCRIPT), ORG, *args]
    if outputs:
        cmd += ["--outputs-file", outputs]
    return run(cmd, env)


def test_script_is_valid_bash():
    assert subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True).returncode == 0


def test_dry_run_calls_nothing_and_covers_all_four_repositories(run_env, outputs_file):
    done = script(env=run_env, outputs=str(outputs_file))
    assert done.returncode == 0, done.stderr
    assert read_log(run_env) == []                                  # no gh, no terraform
    assert "DRY RUN" in done.stdout
    for name in REPOS.values():
        assert f"{ORG}/{name}" in done.stdout


def test_no_account_id_is_ever_printed(run_env, outputs_file):
    for extra in ([], ["--apply"]):
        done = script(*extra, env=run_env, outputs=str(outputs_file))
        assert done.returncode == 0, done.stderr
        assert FAKE_ACCOUNT not in done.stdout + done.stderr
        assert not re.search(r"\d{12}", done.stdout + done.stderr)
        assert "<account-id>" in done.stdout


def test_apply_sends_the_real_values_but_only_on_stdin(run_env, outputs_file):
    script("--apply", env=run_env, outputs=str(outputs_file))
    secrets = [c for c in read_log(run_env) if c["args"][:2] == ["secret", "set"]]
    assert secrets
    assert all(FAKE_ACCOUNT not in " ".join(c["args"]) for c in secrets)          # never on a command line
    assert any(FAKE_ACCOUNT in c["stdin"] for c in secrets)                       # the real value did reach gh


@pytest.mark.parametrize("key", REPOS)
def test_each_repository_gets_variables_secrets_environments_and_a_ruleset(run_env, outputs_file, key):
    assert script("--apply", env=run_env, outputs=str(outputs_file)).returncode == 0
    repo = f"{ORG}/{REPOS[key]}"
    calls = [c for c in read_log(run_env) if repo in " ".join(c["args"])]

    variables = {c["args"][2] for c in calls if c["args"][:2] == ["variable", "set"]}
    assert variables == {"AWS_REGION"}

    repo_secrets = {c["args"][2] for c in calls if c["args"][:2] == ["secret", "set"] and "--env" not in c["args"]}
    assert repo_secrets == {
        "infra": {"TF_STATE_BUCKET", "AWS_PLAN_ROLE_ARN", "AWS_DRIFT_ROLE_ARN"},
        "app": {"TF_STATE_BUCKET", "AWS_BUILD_ROLE_ARN", "ECR_REPOSITORY"},
        "ml": set(),          # the ML names come from SSM /finrisk/shared/*
        "knowledge": {"KB_BUCKET", "AWS_KB_BUILD_ROLE_ARN"},
    }[key]

    env_secrets = {c["args"][c["args"].index("--env") + 1]: c["args"][2] for c in calls if c["args"][:2] == ["secret", "set"] and "--env" in c["args"]}
    assert set(env_secrets) == set(ENV_NAMES[key])
    assert set(env_secrets.values()) == {"AWS_ROLE_ARN"}          # ONE naming rule for all four repositories

    # the Environment's secret is the ROLE OF THAT ENVIRONMENT (stdin of the call)
    for c in calls:
        if c["args"][:2] == ["secret", "set"] and "--env" in c["args"]:
            env = c["args"][c["args"].index("--env") + 1]
            expected = {"infra": f"finrisk-infra-apply-{env.removeprefix('infra-')}", "app": f"finrisk-app-deploy-{env}",
                        "knowledge": f"finrisk-kb-promote-{env}",
                        "ml": {"ml": "finrisk-ml-train", "model-approval": "finrisk-ml-approve", "simulation": "finrisk-ml-feedback"}.get(env, f"finrisk-ml-promote-{env}")}[key]
            assert c["stdin"].endswith(f":role/{expected}"), (env, c["stdin"])


@pytest.mark.parametrize("key", REPOS)
def test_environments_have_reviewers_where_marked_and_deploy_only_from_main(run_env, outputs_file, key):
    script("--apply", env=run_env, outputs=str(outputs_file))
    repo = f"{ORG}/{REPOS[key]}"
    puts = {c["args"][c["args"].index("-X") + 2].rsplit("/", 1)[1]: json.loads(c["stdin"]) for c in read_log(run_env)
            if c["tool"] == "gh" and c["args"][:3] == ["api", "-X", "PUT"] and f"repos/{repo}/environments/" in c["args"][3]}
    assert set(puts) == set(ENV_NAMES[key])
    for env, body in puts.items():
        assert (len(body["reviewers"]) > 0) == (env in REVIEWERS[key]), env
        assert body["deployment_branch_policy"] == {"protected_branches": False, "custom_branch_policies": True}
    policies = [json.loads(c["stdin"]) for c in read_log(run_env)
                if c["args"][:3] == ["api", "-X", "POST"] and f"repos/{repo}/environments/" in c["args"][3] and c["args"][3].endswith("deployment-branch-policies")]
    assert len(policies) == len(ENV_NAMES[key]) and all(p == {"name": "main", "type": "branch"} for p in policies)


@pytest.mark.parametrize("key", REPOS)
def test_ruleset_protect_main_requires_the_agreed_checks(run_env, outputs_file, key):
    script("--apply", env=run_env, outputs=str(outputs_file))
    repo = f"{ORG}/{REPOS[key]}"
    posts = [json.loads(c["stdin"]) for c in read_log(run_env)
             if c["args"][:3] == ["api", "-X", "POST"] and c["args"][3] == f"repos/{repo}/rulesets"]
    assert len(posts) == 1
    ruleset = posts[0]
    assert ruleset["name"] == "protect-main" and ruleset["enforcement"] == "active"
    assert ruleset["conditions"]["ref_name"]["include"] == ["refs/heads/main"]
    kinds = {r["type"] for r in ruleset["rules"]}
    assert {"deletion", "non_fast_forward", "pull_request", "required_status_checks"} <= kinds
    status = next(r for r in ruleset["rules"] if r["type"] == "required_status_checks")
    assert [c["context"] for c in status["parameters"]["required_status_checks"]] == CHECKS[key]
    assert ruleset["bypass_actors"] == []


def test_the_check_table_in_the_header_matches_the_code():
    text = SCRIPT.read_text(encoding="utf-8")
    for key, checks in CHECKS.items():
        assert f'{key})' in text
    header = text.split("set -euo pipefail")[0]
    for name, checks in (("finrisk-infra", CHECKS["infra"]), ("finrisk-app", CHECKS["app"]), ("finrisk-ml", CHECKS["ml"]), ("finrisk-knowledge", CHECKS["knowledge"])):
        assert re.search(rf"{name}\s+{'  '.join(checks)}\s", header), name


def test_an_existing_ruleset_is_updated_not_duplicated(run_env, outputs_file, tmp_path):
    """gh returns an id for `rulesets` -> the script PUTs to it."""
    fake = tmp_path / "fakebin" / "gh"
    fake.write_text(fake.read_text().replace('if args[:2] == ["api", "user"]:', 'if len(args) > 1 and args[1].endswith("/rulesets"):\n    print("77")\nif args[:2] == ["api", "user"]:'))
    script("--apply", "--only", "ml", env=run_env, outputs=str(outputs_file))
    calls = read_log(run_env)
    assert any(c["args"][:3] == ["api", "-X", "PUT"] and c["args"][3].endswith("/rulesets/77") for c in calls)
    assert not any(c["args"][:3] == ["api", "-X", "POST"] and c["args"][3].endswith("/rulesets") for c in calls)


def test_a_different_organisation_stops_the_apply_before_any_change(run_env, outputs_file):
    done = run(["bash", str(SCRIPT), "someone-else", "--apply", "--outputs-file", str(outputs_file)], run_env)
    assert done.returncode == 1
    assert "trust" in done.stderr
    assert read_log(run_env) == []


def test_only_limits_the_repositories(run_env, outputs_file):
    done = script("--only", "ml,knowledge", env=run_env, outputs=str(outputs_file))
    assert f"{ORG}/finrisk-ml" in done.stdout and f"{ORG}/finrisk-knowledge" in done.stdout
    assert f"{ORG}/finrisk-infra" not in done.stdout and f"{ORG}/finrisk-app" not in done.stdout


def test_without_an_outputs_file_it_reads_terraform_output_of_bootstrap(run_env, outputs_file):
    run_env["FAKE_TF_OUTPUT_JSON"] = str(outputs_file)
    done = run(["bash", str(SCRIPT), ORG, "--bootstrap-dir", "/somewhere/finrisk-bootstrap"], run_env)
    assert done.returncode == 0, done.stderr
    calls = read_log(run_env)
    assert [c["chdir"] for c in calls if c["tool"] == "terraform"] == ["/somewhere/finrisk-bootstrap"]
    assert not [c for c in calls if c["tool"] == "gh"]                # still a dry run


def test_bad_arguments_are_refused(run_env, outputs_file):
    assert script("--approvals", "x", env=run_env, outputs=str(outputs_file)).returncode == 2
    assert run(["bash", str(SCRIPT), "bad/org", "--outputs-file", str(outputs_file)], run_env).returncode == 2
    assert script("--only", "nope", env=run_env, outputs=str(outputs_file)).returncode == 2


def test_the_simulation_environment_of_finrisk_ml_is_created_without_a_reviewer_and_holds_the_feedback_role(run_env, outputs_file):
    """Week 13b: replay.yml runs in Environment `simulation` with the role finrisk-ml-feedback -- visible in the dry run too."""
    dry = script("--only", "ml", env=run_env, outputs=str(outputs_file))
    assert dry.returncode == 0, dry.stderr
    assert read_log(run_env) == []                                                         # a dry run calls nothing
    assert "repos/fraud-detection-app/finrisk-ml/environments/simulation" in dry.stdout     # the Environment is created ...
    assert re.search(r"gh secret set AWS_ROLE_ARN --repo fraud-detection-app/finrisk-ml --env simulation", dry.stdout)   # ... with its secret
    assert re.search(r"environment secret|--env simulation", dry.stdout)
    assert "role/finrisk-ml-feedback" in dry.stdout or "<account-id>" in dry.stdout        # the account id is hidden

    script("--apply", "--only", "ml", env=run_env, outputs=str(outputs_file))
    calls = read_log(run_env)
    put = [c for c in calls if c["args"][:3] == ["api", "-X", "PUT"] and c["args"][3].endswith("/environments/simulation")]
    assert len(put) == 1 and json.loads(put[0]["stdin"])["reviewers"] == []                 # no reviewer
    assert json.loads(put[0]["stdin"])["deployment_branch_policy"] == {"protected_branches": False, "custom_branch_policies": True}   # main only
    secret = [c for c in calls if c["args"][:2] == ["secret", "set"] and c["args"][-2:] == ["--env", "simulation"]]
    assert len(secret) == 1 and secret[0]["args"][2] == "AWS_ROLE_ARN"
    assert secret[0]["stdin"].endswith(":role/finrisk-ml-feedback")                       # stdin only, never on the command line
    assert FAKE_ACCOUNT not in " ".join(secret[0]["args"])


def test_the_other_ml_environments_keep_their_reviewers(run_env, outputs_file):
    script("--apply", "--only", "ml", env=run_env, outputs=str(outputs_file))
    puts = {c["args"][3].rsplit("/", 1)[1]: json.loads(c["stdin"]) for c in read_log(run_env)
            if c["args"][:3] == ["api", "-X", "PUT"] and "/environments/" in c["args"][3]}
    assert {e for e, b in puts.items() if b["reviewers"]} == {"model-approval", "pre-prod", "prod"}
    assert set(puts) == {"ml", "model-approval", "simulation", *ENVIRONMENTS}

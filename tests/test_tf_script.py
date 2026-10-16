"""scripts/tf.sh -- scope -> folder, state key, workspace and tfvars; read-only plans; drift exit codes.
A fake `terraform` records its arguments, so no AWS and no real Terraform is involved."""

from __future__ import annotations

import json
import shutil
import subprocess

import pytest

from conftest import ROOT, read_log, run

PLAN_JSON = {"resource_changes": [{"address": "aws_s3_bucket.env", "change": {"actions": ["create"]}}], "resource_drift": []}
DRIFT_JSON = {"resource_changes": [], "resource_drift": [{"address": "aws_iam_role.runtime", "change": {"actions": ["update"]}}]}


@pytest.fixture
def repo(tmp_path):
    """A copy of scripts/ with empty shared/ and envs/ beside it: tf.sh writes tfplan files next to the code."""
    shutil.copytree(ROOT / "scripts", tmp_path / "repo" / "scripts")
    for d in ("shared", "envs"):
        (tmp_path / "repo" / d).mkdir()
    (tmp_path / "repo" / "envs" / "backend.tf").write_text("terraform { backend \"s3\" {} }\n")
    (tmp_path / "plan.json").write_text(json.dumps(PLAN_JSON))
    return tmp_path / "repo"


@pytest.fixture
def env(run_env, tmp_path):
    run_env.update(STATE_BUCKET="state-bucket-name", AWS_REGION="ap-southeast-2", FAKE_TF_PLAN_JSON=str(tmp_path / "plan.json"))
    return run_env


def tf(repo, env, *args):
    return run(["bash", str(repo / "scripts" / "tf.sh"), *args], env)


def terraform_calls(env):
    return [(c["chdir"], c["args"]) for c in read_log(env) if c["tool"] == "terraform"]


def test_script_is_valid_bash():
    assert subprocess.run(["bash", "-n", str(ROOT / "scripts" / "tf.sh")], capture_output=True).returncode == 0


@pytest.mark.parametrize("scope,folder,key", [("shared", "shared", "infra/shared.tfstate"), ("dev", "envs", "infra/env.tfstate"), ("pre-prod", "envs", "infra/env.tfstate")])
def test_init_connects_to_the_right_state_object(repo, env, scope, folder, key):
    done = tf(repo, env, "init", scope)
    assert done.returncode == 0, done.stderr
    [(chdir, args)] = terraform_calls(env)
    assert chdir == folder and args[0] == "init"
    assert "-backend-config=bucket=state-bucket-name" in args and f"-backend-config=key={key}" in args
    assert "-backend-config=region=ap-southeast-2" in args and "-backend-config=use_lockfile=true" in args


def test_init_needs_the_bucket_and_region(repo, env):
    env.pop("STATE_BUCKET")
    done = tf(repo, env, "init", "dev")
    assert done.returncode != 0 and "STATE_BUCKET" in done.stderr
    assert terraform_calls(env) == []


def test_unknown_scope_is_refused(repo, env):
    assert tf(repo, env, "plan", "staging").returncode == 2
    assert terraform_calls(env) == []


def test_plan_of_an_environment_selects_its_workspace_and_its_tfvars(repo, env):
    done = tf(repo, env, "plan", "pre-prod")
    assert done.returncode == 0, done.stderr
    calls = terraform_calls(env)
    assert ("envs", ["workspace", "select", "-or-create", "pre-prod"]) in calls
    plan = next(a for c, a in calls if a[0] == "plan")
    assert "-var-file=pre-prod.tfvars" in plan and "-out=tfplan" in plan and "-lock-timeout=5m" in plan
    assert "-lock=false" not in plan and "-detailed-exitcode" not in plan
    assert calls.index(("envs", ["workspace", "select", "-or-create", "pre-prod"])) < calls.index(("envs", plan))
    assert "+ 1 to add" in done.stdout                       # the summary


def test_plan_of_shared_uses_the_default_workspace_and_no_tfvars(repo, env):
    tf(repo, env, "plan", "shared")
    calls = terraform_calls(env)
    assert not any(a[0] == "workspace" for _, a in calls)
    plan = next(a for _, a in calls if a[0] == "plan")
    assert not any(x.startswith("-var-file") for x in plan)


def test_summary_goes_to_the_github_step_summary(repo, env, tmp_path):
    env["GITHUB_STEP_SUMMARY"] = str(tmp_path / "step.md")
    env["SUMMARY_FILE"] = str(tmp_path / "scope.md")
    tf(repo, env, "plan", "dev")
    assert "plan · `dev`" in (tmp_path / "step.md").read_text() and "scope=dev" in (tmp_path / "scope.md").read_text()


def test_read_only_plan_never_locks_and_selects_an_existing_workspace(repo, env):
    env.update(TF_READ_ONLY="1", FAKE_TF_WORKSPACES="* default\n  dev\n  prod")
    done = tf(repo, env, "plan", "dev")
    assert done.returncode == 0, done.stderr
    calls = terraform_calls(env)
    assert ("envs", ["workspace", "select", "dev"]) in calls
    assert not any("-or-create" in a for _, a in calls) and not any(a[:2] == ["workspace", "new"] for _, a in calls)
    plan = next(a for _, a in calls if a[0] == "plan")
    assert "-lock=false" in plan and not any(x.startswith("-lock-timeout") for x in plan)


def test_read_only_plan_of_a_workspace_that_does_not_exist_yet_plans_against_empty_state(repo, env):
    env.update(TF_READ_ONLY="1", FAKE_TF_WORKSPACES="* default")
    done = tf(repo, env, "plan", "sit")
    assert done.returncode == 0, done.stderr
    calls = terraform_calls(env)
    assert ("envs", ["init", "-input=false", "-reconfigure", "-backend=false"]) in calls
    assert ("envs", ["workspace", "new", "sit"]) in calls
    assert not (repo / "envs" / "backend.tf").exists()             # local state in the runner's copy only
    assert "has not been applied yet" in done.stdout


def test_a_broken_login_is_not_mistaken_for_a_missing_workspace(repo, env):
    env.update(TF_READ_ONLY="1", FAKE_TF_WORKSPACE_LIST_EXIT="1")
    done = tf(repo, env, "plan", "dev")
    assert done.returncode != 0
    assert not any(a[:2] == ["workspace", "new"] for _, a in terraform_calls(env))
    assert (repo / "envs" / "backend.tf").exists()


@pytest.mark.parametrize("plan_exit,expected", [(0, 0), (2, 2), (1, 1)])
def test_drift_exit_codes(repo, env, tmp_path, plan_exit, expected):
    env.update(TF_READ_ONLY="1", TF_DRIFT="1", FAKE_TF_WORKSPACES="* default\n  dev", FAKE_TF_PLAN_EXIT=str(plan_exit))
    if plan_exit == 2:
        (tmp_path / "plan.json").write_text(json.dumps(DRIFT_JSON))
    done = tf(repo, env, "plan", "dev")
    assert done.returncode == expected
    plan = next(a for _, a in terraform_calls(env) if a[0] == "plan")
    assert "-detailed-exitcode" in plan
    if plan_exit == 2:
        assert "::error" in done.stdout and "aws_iam_role.runtime" in done.stdout and "DRIFT" in done.stdout


def test_apply_uses_exactly_the_saved_plan(repo, env):
    assert tf(repo, env, "apply", "dev").returncode == 1            # no plan yet
    assert terraform_calls(env) == []
    tf(repo, env, "plan", "dev")
    assert tf(repo, env, "apply", "dev").returncode == 0
    last = terraform_calls(env)[-1]
    assert last[0] == "envs" and last[1][0] == "apply" and last[1][-1] == "tfplan"
    assert not any(x.startswith("-var") for x in last[1])           # the plan already holds the variables

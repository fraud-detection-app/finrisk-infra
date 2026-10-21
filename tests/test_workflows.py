"""The three workflows: they parse, they chain in the order the contract says, every action is pinned to the agreed
major, every role comes from a secret that bootstrap/ really creates, and the required-check names are real job names."""

from __future__ import annotations

import re

import pytest
import yaml

from conftest import ENVIRONMENTS, ROOT

WORKFLOWS = ROOT / ".github" / "workflows"
SCOPES = ["shared", *ENVIRONMENTS]

ALLOWED_ACTIONS = {
    "actions/checkout": "v7",
    "actions/setup-python": "v7",
    "actions/upload-artifact": "v7",
    "actions/download-artifact": "v8",
    "aws-actions/configure-aws-credentials": "v6",
    "hashicorp/setup-terraform": "v4",
}


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


def triggers(wf: dict) -> dict:
    return wf.get("on") or wf[True]          # PyYAML reads the key `on` as the boolean True


def all_steps(wf: dict):
    for job_id, job in wf["jobs"].items():
        for step in job["steps"]:
            yield job_id, job, step


def code_of(name: str) -> str:
    return "\n".join(l for l in (WORKFLOWS / name).read_text(encoding="utf-8").splitlines() if not l.lstrip().startswith("#"))


def brace_block(text: str, start: int) -> str:
    depth, i = 0, text.index("{", start)
    for j in range(i, len(text)):
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        if depth == 0:
            return text[i + 1:j]
    raise AssertionError("unbalanced braces")


def bootstrap_output_names(local: str) -> dict[str, set[str]]:
    text = (ROOT / "bootstrap" / "outputs.tf").read_text(encoding="utf-8")
    block = brace_block(text, text.index(f"  {local} = {{"))
    out = {}
    for repo in ("infra", "app", "ml", "knowledge"):
        inner = brace_block(block, re.search(rf"\b{repo}\s*=\s*{{", block).start())
        out[repo] = set(re.findall(r"^\s*([A-Z][A-Z_]+)\s*=", inner, re.M))
    return out


@pytest.fixture(scope="module", params=["infra-ci.yml", "infra-deliver.yml", "drift.yml"])
def wf_name(request):
    return request.param


def test_every_workflow_parses_and_has_jobs(wf_name):
    wf = load(wf_name)
    assert wf["name"] and wf["jobs"]
    assert wf["permissions"] == {"contents": "read"}                          # least privilege by default


def test_every_job_runs_on_the_pinned_runner_image(wf_name):
    for job_id, job in load(wf_name)["jobs"].items():
        assert job["runs-on"] == "ubuntu-24.04", f"{wf_name} job {job_id}: pin the runner (ubuntu-24.04), not a moving label like ubuntu-latest"


def test_actions_are_pinned_to_the_agreed_majors(wf_name):
    seen = set()
    for _, _, step in all_steps(load(wf_name)):
        if "uses" in step:
            repo, _, ref = step["uses"].partition("@")
            assert repo in ALLOWED_ACTIONS, repo
            assert ref == ALLOWED_ACTIONS[repo], f"{repo}@{ref}"
            seen.add(repo)
    assert "actions/checkout" in seen


def test_terraform_is_setup_without_the_wrapper_and_at_the_agreed_version(wf_name):
    for _, _, step in all_steps(load(wf_name)):
        if step.get("uses", "").startswith("hashicorp/setup-terraform"):
            assert step["with"]["terraform_version"] == "1.15.8" and step["with"]["terraform_wrapper"] is False


def test_no_docker_buildx_and_no_pull_request_target(wf_name):
    code = code_of(wf_name)
    assert "setup-buildx" not in code and "pull_request_target" not in code


def test_every_job_that_assumes_a_role_may_get_a_token_and_masks_the_account_id_next(wf_name):
    for job_id, job in load(wf_name)["jobs"].items():
        steps = job["steps"]
        idx = [i for i, s in enumerate(steps) if s.get("uses", "").startswith("aws-actions/configure-aws-credentials")]
        if not idx:
            continue
        assert job["permissions"]["id-token"] == "write", job_id
        assert job["permissions"]["contents"] == "read", job_id
        following = steps[idx[0] + 1]
        assert "::add-mask::" in following["run"] and "get-caller-identity" in following["run"], job_id


def test_scripts_the_workflows_call_exist_and_the_state_bucket_is_a_secret(wf_name):
    code = code_of(wf_name)
    for script in set(re.findall(r"scripts/([\w.]+)", code)):
        assert (ROOT / "scripts" / script).exists(), script
    for _, job, _ in all_steps(load(wf_name)):
        env = job.get("env", {})
        if "STATE_BUCKET" in env:
            assert env["STATE_BUCKET"] == "${{ secrets.TF_STATE_BUCKET }}" and env["AWS_REGION"] == "${{ vars.AWS_REGION }}"


def test_every_secret_and_variable_a_workflow_reads_is_created_by_bootstrap():
    secrets = bootstrap_output_names("repo_secrets")["infra"]
    variables = bootstrap_output_names("repo_variables")["infra"]
    used_s, used_v = set(), set()
    for name in ("infra-ci.yml", "infra-deliver.yml", "drift.yml"):
        used_s |= set(re.findall(r"secrets\.([A-Z_]+)", code_of(name)))
        used_v |= set(re.findall(r"vars\.([A-Z_]+)", code_of(name)))
    assert used_s <= secrets | {"AWS_ROLE_ARN"}, used_s - secrets
    assert used_v == variables == {"AWS_REGION"}
    # and every repository secret of infra is actually used (a name nobody reads is a leftover)
    assert secrets == used_s - {"AWS_ROLE_ARN"}


# ------------------------------------------------------------------ infra-ci
def test_ci_runs_on_every_pull_request_to_main_without_a_paths_filter():
    on = triggers(load("infra-ci.yml"))
    assert list(on) == ["pull_request"] and on["pull_request"] == {"branches": ["main"]}


def test_required_check_names_are_real_job_names():
    ci = load("infra-ci.yml")
    required = re.search(r'infra\)\s+echo "([^"]+)"', (ROOT / "scripts" / "github_bootstrap.sh").read_text(encoding="utf-8")).group(1).split()
    assert required == ["plan", "terraform-checks"]
    names = {(job.get("name") or job_id) for job_id, job in ci["jobs"].items()}
    assert set(required) <= names
    # a matrix job is called "plan (dev)": the check the ruleset waits for is the aggregating job named exactly `plan`
    assert "matrix" not in ci["jobs"]["plan"].get("strategy", {}) and ci["jobs"]["plan"]["needs"] == "plan-scope"
    assert ci["jobs"]["plan"]["if"].strip() in ("${{ always() }}", "always()")


def test_plan_matrix_covers_shared_and_every_environment_with_the_read_only_role():
    job = load("infra-ci.yml")["jobs"]["plan-scope"]
    assert job["strategy"]["matrix"]["scope"] == SCOPES and job["strategy"]["fail-fast"] is False
    assert "environment" not in job                                              # the sub must be `pull_request`
    assert job["env"]["TF_READ_ONLY"] == "1"
    roles = [s["with"]["role-to-assume"] for s in job["steps"] if s.get("uses", "").startswith("aws-actions/configure")]
    assert roles == ["${{ secrets.AWS_PLAN_ROLE_ARN }}"]
    assert "github.event.pull_request.head.repo.full_name == github.repository" in job["if"]    # no OIDC for forks


def test_terraform_checks_run_the_offline_script_and_pytest():
    runs = " ".join(s.get("run", "") for s in load("infra-ci.yml")["jobs"]["terraform-checks"]["steps"])
    assert "scripts/tf_checks.sh" in runs and "pytest" in runs
    assert "permissions" not in load("infra-ci.yml")["jobs"]["terraform-checks"]            # no id-token: it never reaches AWS


def test_fork_pull_requests_are_explained_in_the_summary():
    text = (WORKFLOWS / "infra-ci.yml").read_text(encoding="utf-8")
    assert "fork" in text and "OIDC" in text


# ------------------------------------------------------------------ infra-deliver
def test_deliver_chains_shared_then_the_environments_in_order():
    wf = load("infra-deliver.yml")
    on = triggers(wf)
    assert on["push"]["branches"] == ["main"] and on["push"]["paths"] == ["shared/**", "envs/**"] and "workflow_dispatch" in on
    jobs = wf["jobs"]
    assert list(jobs) == [f"apply-{s}" for s in SCOPES]
    assert "needs" not in jobs["apply-shared"]
    for prev, cur in zip(SCOPES, SCOPES[1:]):
        assert jobs[f"apply-{cur}"]["needs"] == f"apply-{prev}"
    assert wf["concurrency"] == {"group": "infra-deliver", "cancel-in-progress": False}


def test_each_apply_job_uses_its_environment_its_role_and_plan_then_apply_tfplan():
    for scope in SCOPES:
        job = load("infra-deliver.yml")["jobs"][f"apply-{scope}"]
        assert job["environment"] == f"infra-{scope}"
        assert job["env"]["SCOPE"] == scope
        roles = [s["with"]["role-to-assume"] for s in job["steps"] if s.get("uses", "").startswith("aws-actions/configure")]
        assert roles == ["${{ secrets.AWS_ROLE_ARN }}"]                         # the ENVIRONMENT secret of that job
        runs = [s["run"] for s in job["steps"] if "run" in s]
        order = [i for cmd in ('tf.sh init "$SCOPE"', 'tf.sh plan "$SCOPE"', 'tf.sh apply "$SCOPE"') for i, r in enumerate(runs) if cmd in r]
        assert order == sorted(order) and len(order) == 3, scope
        assert "TF_READ_ONLY" not in job["env"] and "TF_DRIFT" not in job["env"]


def test_the_environments_exist_in_bootstrap_and_have_a_matching_role():
    outputs = (ROOT / "bootstrap" / "outputs.tf").read_text(encoding="utf-8")
    roles = (ROOT / "bootstrap" / "roles_infra.tf").read_text(encoding="utf-8")
    for scope in SCOPES:
        assert f"infra-{scope}" in outputs or '"infra-${e}"' in outputs
        assert f"environment:infra-{scope}" in roles or "environment:infra-${e}" in roles


# ------------------------------------------------------------------ drift
def test_drift_runs_nightly_and_on_demand_with_the_drift_role_and_detailed_exitcode():
    wf = load("drift.yml")
    on = triggers(wf)
    assert len(on["schedule"]) == 1 and re.fullmatch(r"\d+ \d+ \* \* \*", on["schedule"][0]["cron"]) and "workflow_dispatch" in on
    job = wf["jobs"]["drift"]
    assert job["strategy"]["matrix"]["scope"] == SCOPES and job["strategy"]["fail-fast"] is False
    assert job["env"]["TF_DRIFT"] == "1" and job["env"]["TF_READ_ONLY"] == "1"
    assert "environment" not in job
    roles = [s["with"]["role-to-assume"] for s in job["steps"] if s.get("uses", "").startswith("aws-actions/configure")]
    assert roles == ["${{ secrets.AWS_DRIFT_ROLE_ARN }}"]
    assert job["if"] == "github.ref == 'refs/heads/main'"                       # the role trusts main only


def test_the_scripts_turn_drift_into_exit_code_2():
    assert "-detailed-exitcode" in (ROOT / "scripts" / "tf.sh").read_text(encoding="utf-8")

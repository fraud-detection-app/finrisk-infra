"""Shared helpers: the repository root, a fake `gh`, a fake `terraform`, and a fake `terraform output -json`."""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENTS = ["dev", "sit", "pre-prod", "prod"]
ORG = "fraud-detection-app"
REPOS = {"infra": "finrisk-infra", "app": "finrisk-app", "ml": "finrisk-ml", "knowledge": "finrisk-knowledge"}

# Folders that tools generate (or that hold git's own bookkeeping). A scan of "what is committed" must never read them:
# on a CI runner .git/ contains fetched refs and shas, .terraform/ and .venv/ contain other people's files.
GENERATED_DIRS = {".git", ".terraform", ".venv", "__pycache__", ".pytest_cache"}

# Files Terraform and the instructor's real apply leave next to the code. .gitignore keeps them out of git, so a scan of "what
# is committed" must not read them either: `bootstrap/terraform.tfstate` of a LIVE bootstrap folder holds the account id by design.
# (With git, `git ls-files --exclude-standard` already leaves them out; this is the same rule for a folder that is not a checkout.)
GITIGNORED_NAMES = {"plan", "tfplan", "tfplan.json", "crash.log", "outputs.json", "oidc_subjects.auto.tfvars.json", ".env"}


def is_gitignored(name: str) -> bool:
    return name in GITIGNORED_NAMES or name.endswith(".tfplan") or name.endswith(".tfstate") or ".tfstate." in name


def repo_files(root: Path = ROOT) -> list[Path]:
    """The files of the repository that git tracks (or would track): `git ls-files` when `root` is a git checkout and git
    is installed, otherwise a walk of the folder that does not enter GENERATED_DIRS or another
    checkout nested inside it (CI may check a sibling repository out into a subfolder). Either way nothing from a
    generated folder, and never a .pyc."""
    names: list[Path] | None = None
    if (root / ".git").exists() and shutil.which("git"):
        done = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                              capture_output=True, text=True)
        if done.returncode == 0:
            names = [root / n for n in done.stdout.split("\0") if n]
    if names is None:
        names = []
        for folder, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in GENERATED_DIRS and not (Path(folder) / d / ".git").exists()]           # prune: do not even descend
            names.extend(Path(folder) / f for f in files)
    return sorted(p for p in names if p.is_file() and p.suffix != ".pyc" and not is_gitignored(p.name)
                  and not GENERATED_DIRS.intersection(p.relative_to(root).parts))


# A made-up 12-digit account id. It must never appear in anything the scripts PRINT.
FAKE_ACCOUNT = "210987654321"

FAKE_GH = '''#!/usr/bin/env python3
"""Records every call (arguments + whatever arrives on stdin) as one JSON line in $FAKE_LOG. Changes nothing."""
import json, os, sys
args = sys.argv[1:]
data = "" if sys.stdin.isatty() else sys.stdin.read()
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps({"tool": "gh", "args": args, "stdin": data}) + "\\n")
if args[:2] == ["api", "user"]:
    print("4242")
# GET repos/<org>/<name>/actions/oidc/customization/sub: answer like GitHub does for a repository created after 15 July 2026.
# FAKE_GH_MISSING = names that do not exist (404); FAKE_GH_CLASSIC = names that report no prefix (an older repository).
if len(args) >= 2 and args[0] == "api" and args[1].endswith("/actions/oidc/customization/sub"):
    _, org, name = args[1].split("/")[:3]
    if name in os.environ.get("FAKE_GH_MISSING", "").split(","):
        print("gh: Not Found (HTTP 404)", file=sys.stderr); sys.exit(1)
    if name in os.environ.get("FAKE_GH_CLASSIC", "").split(","):
        print("null" if "--jq" in args else "{}")
    else:
        ids = {"finrisk-infra": 1422750317, "finrisk-app": 1422750390, "finrisk-ml": 1422750465, "finrisk-knowledge": 1422750548}
        print(f"repo:{org}@343247080/{name}@{ids.get(name, 1422759999)}")
'''

FAKE_TERRAFORM = '''#!/usr/bin/env python3
"""A terraform that only records its arguments. Behaviour comes from environment variables:
FAKE_TF_WORKSPACES (text for `workspace list`), FAKE_TF_PLAN_EXIT, FAKE_TF_WORKSPACE_LIST_EXIT, FAKE_TF_PLAN_JSON (file),
FAKE_TF_OUTPUT_JSON (file, for `terraform output -json`)."""
import json, os, sys
args = sys.argv[1:]
chdir = ""
if args and args[0].startswith("-chdir="):
    chdir = args[0][len("-chdir="):]
    args = args[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps({"tool": "terraform", "chdir": chdir, "args": args}) + "\\n")
cmd = args[:2] if args[:1] == ["workspace"] else args[:1]
if cmd == ["workspace", "list"]:
    code = int(os.environ.get("FAKE_TF_WORKSPACE_LIST_EXIT", "0"))
    if code:
        print("Error: AccessDenied", file=sys.stderr); sys.exit(code)
    print(os.environ.get("FAKE_TF_WORKSPACES", "* default"))
elif cmd == ["plan"]:
    out = [a for a in args if a.startswith("-out=")]
    if out:
        open(os.path.join(chdir or ".", out[0][5:]), "w").write("plan")
    sys.exit(int(os.environ.get("FAKE_TF_PLAN_EXIT", "0")))
elif cmd == ["show"]:
    print(open(os.environ["FAKE_TF_PLAN_JSON"]).read())
elif cmd == ["output"]:
    print(open(os.environ["FAKE_TF_OUTPUT_JSON"]).read())
'''


def _write_tool(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@pytest.fixture
def fake_bin(tmp_path: Path) -> Path:
    """A folder with fake `gh` and `terraform`, to put first on PATH."""
    directory = tmp_path / "fakebin"
    directory.mkdir()
    _write_tool(directory, "gh", FAKE_GH)
    _write_tool(directory, "terraform", FAKE_TERRAFORM)
    return directory


@pytest.fixture
def run_env(tmp_path: Path, fake_bin: Path) -> dict:
    env = dict(os.environ)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["FAKE_LOG"] = str(tmp_path / "calls.jsonl")
    env.pop("GITHUB_STEP_SUMMARY", None)
    return env


def read_log(env: dict) -> list[dict]:
    path = Path(env["FAKE_LOG"])
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def run(cmd: list[str], env: dict, cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True, timeout=120)


def role_arn(name: str) -> str:
    return f"arn:aws:iam::{FAKE_ACCOUNT}:role/{name}"


def terraform_outputs() -> dict:
    """What `terraform output -json` prints for bootstrap/ -- the same shape as outputs.tf builds."""
    state = f"finrisk-tfstate-{FAKE_ACCOUNT}-ap-southeast-2-an"
    ecr = f"{FAKE_ACCOUNT}.dkr.ecr.ap-southeast-2.amazonaws.com"
    env_role = {
        "infra": {**{"infra-shared": ("finrisk-infra-apply-shared", "AWS_ROLE_ARN")},
                  **{f"infra-{e}": (f"finrisk-infra-apply-{e}", "AWS_ROLE_ARN") for e in ENVIRONMENTS}},
        "app": {e: (f"finrisk-app-deploy-{e}", "AWS_ROLE_ARN") for e in ENVIRONMENTS},
        "ml": {"ml": ("finrisk-ml-train", "AWS_ROLE_ARN"), "model-approval": ("finrisk-ml-approve", "AWS_ROLE_ARN"),
               "simulation": ("finrisk-ml-feedback", "AWS_ROLE_ARN"),
               **{e: (f"finrisk-ml-promote-{e}", "AWS_ROLE_ARN") for e in ENVIRONMENTS}},
        "knowledge": {e: (f"finrisk-kb-promote-{e}", "AWS_ROLE_ARN") for e in ENVIRONMENTS},
    }
    values = {
        "github_org": ORG,
        "repositories": REPOS,
        "aws_region": "ap-southeast-2",
        "github_repo_variables": {
            "infra": {"AWS_REGION": "ap-southeast-2"}, "app": {"AWS_REGION": "ap-southeast-2"},
            "ml": {"AWS_REGION": "ap-southeast-2"},
            "knowledge": {"AWS_REGION": "ap-southeast-2"},
        },
        "github_repo_secrets": {
            "infra": {"TF_STATE_BUCKET": state, "AWS_PLAN_ROLE_ARN": role_arn("finrisk-infra-plan"), "AWS_DRIFT_ROLE_ARN": role_arn("finrisk-infra-drift")},
            "app": {"TF_STATE_BUCKET": state, "AWS_BUILD_ROLE_ARN": role_arn("finrisk-app-build"), "ECR_REPOSITORY": f"{ecr}/finrisk-app"},
            "ml": {},
            "knowledge": {"KB_BUCKET": f"finrisk-kb-{FAKE_ACCOUNT}-ap-southeast-2-an", "AWS_KB_BUILD_ROLE_ARN": role_arn("finrisk-kb-build")},
        },
        "github_environments": {repo: sorted(envs) for repo, envs in env_role.items()},
        "github_environment_secrets": {
            repo: {env: {secret: role_arn(role)} for env, (role, secret) in envs.items()} for repo, envs in env_role.items()
        },
    }
    return {name: {"value": value, "sensitive": name in ("github_repo_secrets", "github_environment_secrets"), "type": "dynamic"}
            for name, value in values.items()}


@pytest.fixture
def outputs_file(tmp_path: Path) -> Path:
    path = tmp_path / "outputs.json"
    path.write_text(json.dumps(terraform_outputs()), encoding="utf-8")
    return path

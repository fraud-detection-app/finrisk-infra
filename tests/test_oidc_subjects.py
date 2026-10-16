"""scripts/oidc_subjects.sh -- with a fake `gh`: it only reads (GET), prints the four sub prefixes and writes the tfvars file."""

from __future__ import annotations

import json
import re
import subprocess

from conftest import ORG, REPOS, ROOT, read_log, run

SCRIPT = ROOT / "scripts" / "oidc_subjects.sh"
FILE = "oidc_subjects.auto.tfvars.json"
PREFIX = re.compile(r"^repo:[A-Za-z0-9-]+(@[0-9]+)?/[A-Za-z0-9._-]+(@[0-9]+)?$")


def script(*args: str, env: dict, org: str = ORG):
    return run(["bash", str(SCRIPT), org, *args], env)


def test_script_is_valid_bash():
    assert subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True).returncode == 0


def test_it_prints_four_immutable_prefixes_and_writes_the_tfvars_file(run_env, tmp_path):
    out = tmp_path / "finrisk-bootstrap"
    out.mkdir()
    done = script("--out", str(out), env=run_env)
    assert done.returncode == 0, done.stderr
    written = json.loads((out / FILE).read_text(encoding="utf-8"))
    assert list(written) == ["sub_prefixes"]
    assert set(written["sub_prefixes"]) == set(REPOS)
    for key, name in REPOS.items():
        prefix = written["sub_prefixes"][key]
        assert PREFIX.match(prefix)
        assert prefix.startswith(f"repo:{ORG}@343247080/{name}@")      # org id and repository id are both in it
        assert prefix in done.stdout                                    # printed too (the ids are public, not secrets)
    assert str(out / FILE) in done.stdout


def test_it_only_reads_github(run_env, tmp_path):
    assert script("--out", str(tmp_path), env=run_env).returncode == 0
    calls = read_log(run_env)
    assert [c["tool"] for c in calls] == ["gh"] * 4
    for call, name in zip(calls, REPOS.values()):
        assert call["args"][0] == "api"
        assert call["args"][1] == f"repos/{ORG}/{name}/actions/oidc/customization/sub"
        assert "--jq" in call["args"] and ".sub_claim_prefix" in call["args"]
        assert not {"-X", "--method", "-f", "-F", "--input", "--field", "--raw-field"} & set(call["args"])   # a plain GET


def test_the_default_out_folder_is_the_current_folder(run_env, tmp_path):
    done = run(["bash", str(SCRIPT), ORG], run_env, cwd=tmp_path)
    assert done.returncode == 0, done.stderr
    assert (tmp_path / FILE).exists()


def test_a_missing_repository_fails_clearly_and_writes_nothing(run_env, tmp_path):
    run_env["FAKE_GH_MISSING"] = "finrisk-ml,finrisk-knowledge"
    done = script("--out", str(tmp_path), env=run_env)
    assert done.returncode == 1
    assert not (tmp_path / FILE).exists()
    assert "Create the four EMPTY public repositories first" in done.stderr
    assert f"gh repo create {ORG}/finrisk-ml --public" in done.stderr
    assert f"gh repo create {ORG}/finrisk-knowledge --public" in done.stderr
    assert f"gh repo create {ORG}/finrisk-infra --public" not in done.stderr          # only the missing ones are listed


def test_a_repository_without_a_prefix_gets_the_classic_form(run_env, tmp_path):
    run_env["FAKE_GH_CLASSIC"] = "finrisk-app"
    done = script("--out", str(tmp_path), env=run_env)
    assert done.returncode == 0, done.stderr
    written = json.loads((tmp_path / FILE).read_text(encoding="utf-8"))["sub_prefixes"]
    assert written["app"] == f"repo:{ORG}/finrisk-app"
    assert "@" in written["infra"]


def test_repos_override_changes_the_names_asked_for(run_env, tmp_path):
    done = script("--repos", "infra=acme-infra,knowledge=acme.kb", "--out", str(tmp_path), env=run_env)
    assert done.returncode == 0, done.stderr
    asked = [c["args"][1] for c in read_log(run_env)]
    assert asked == [f"repos/{ORG}/{n}/actions/oidc/customization/sub" for n in ("acme-infra", "finrisk-app", "finrisk-ml", "acme.kb")]
    written = json.loads((tmp_path / FILE).read_text(encoding="utf-8"))["sub_prefixes"]
    assert written["infra"].split("/")[1].startswith("acme-infra@") and written["knowledge"].split("/")[1].startswith("acme.kb@")


def test_bad_input_is_refused_before_gh_is_called(run_env, tmp_path):
    for args, org in ((["--out", str(tmp_path / "nope")], ORG), (["--out", str(tmp_path), "--repos", "bogus=x"], ORG),
                      (["--out", str(tmp_path)], "bad/org"), (["--out", str(tmp_path), "--repos", "infra="], ORG)):
        done = script(*args, env=run_env, org=org)
        assert done.returncode == 2, (args, done.stderr)
    assert read_log(run_env) == []
    assert not (tmp_path / FILE).exists()


def test_a_wildcard_answer_is_never_written(run_env, tmp_path, fake_bin):
    # A gh that answers something that is not a subject prefix must not reach the tfvars file.
    (fake_bin / "gh").write_text('#!/bin/sh\necho "repo:acme/*"\n', encoding="utf-8")
    done = script("--out", str(tmp_path), env=run_env)
    assert done.returncode == 1
    assert not (tmp_path / FILE).exists()


def test_no_account_id_and_no_other_files_are_left_behind(run_env, tmp_path):
    out = tmp_path / "out"
    out.mkdir()
    done = script("--out", str(out), env=run_env)
    assert not re.search(r"\d{12}", done.stdout + done.stderr)
    assert [p.name for p in out.iterdir()] == [FILE]


def test_the_written_prefixes_pass_terraforms_validation_shape(run_env, tmp_path):
    # The same regex as bootstrap/variables.tf, so what the script writes is what Terraform accepts.
    variables = (ROOT / "bootstrap" / "variables.tf").read_text(encoding="utf-8")
    assert '^repo:[A-Za-z0-9-]+(@[0-9]+)?/[A-Za-z0-9._-]+(@[0-9]+)?$' in variables
    assert script("--out", str(tmp_path), env=run_env).returncode == 0
    for prefix in json.loads((tmp_path / FILE).read_text(encoding="utf-8"))["sub_prefixes"].values():
        assert PREFIX.match(prefix)

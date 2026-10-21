"""scripts/plan_summary.py -- the + ~ - counts and the list of addresses."""

from __future__ import annotations

import json

from conftest import ROOT, run

import importlib.util

spec = importlib.util.spec_from_file_location("plan_summary", ROOT / "scripts" / "plan_summary.py")
ps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ps)


def rc(address, *actions):
    return {"address": address, "change": {"actions": list(actions)}}


PLAN = {
    "resource_changes": [
        rc("aws_s3_bucket.env", "create"),
        rc("aws_iam_role.runtime", "update"),
        rc("aws_cloudwatch_log_group.app", "delete", "create"),   # a replacement
        rc("aws_ssm_parameter.old", "delete"),
        rc("aws_s3_bucket_versioning.env", "no-op"),
        rc("data.aws_ssm_parameter.ml_bucket", "read"),
    ],
    "resource_drift": [rc("aws_iam_role.runtime", "update")],
}


def test_counts_follow_terraforms_own_arithmetic():
    counts, md = ps.summarize(PLAN, "dev")
    assert counts == {"add": 2, "change": 1, "destroy": 2}          # a replacement is one add AND one destroy
    assert "+ 2 to add · ~ 1 to change · - 2 to destroy" in md
    assert "| `+` | `aws_s3_bucket.env` |" in md
    assert "| `-/+` | `aws_cloudwatch_log_group.app` |" in md
    assert "aws_s3_bucket_versioning.env" not in md                  # no-ops are not listed
    assert md.startswith("<!-- scope=dev add=2 change=1 destroy=2 -->")


def test_no_changes_says_so():
    counts, md = ps.summarize({"resource_changes": [rc("a.b", "no-op")]}, "prod")
    assert counts == {"add": 0, "change": 0, "destroy": 0}
    assert "No changes" in md


def test_a_note_is_shown_instead_of_the_all_clear():
    _, md = ps.summarize({"resource_changes": []}, "dev", note="First plan: dev has not been applied yet")
    assert "First plan" in md and "No changes" not in md


def test_drift_lists_what_changed_outside_terraform():
    _, md = ps.summarize(PLAN, "dev", drift=True)
    assert "### drift · `dev` · DRIFT" in md
    assert "Changed outside Terraform" in md and "- `aws_iam_role.runtime`" in md
    _, clean = ps.summarize({"resource_changes": [], "resource_drift": []}, "dev", drift=True)
    assert "no drift" in clean


def test_combine_makes_one_table_in_pipeline_order(tmp_path):
    for scope, plan in (("prod", {"resource_changes": []}), ("shared", PLAN), ("dev", {"resource_changes": [rc("x.y", "create")]})):
        _, md = ps.summarize(plan, scope)
        (tmp_path / f"summary-{scope}.md").write_text(md, encoding="utf-8")
    text = ps.combine(tmp_path)
    table = text.split("\n\n")[1].splitlines()      # the first table: header, separator, one row per scope
    rows = [line for line in table if line.startswith("| `")]
    assert [r.split("`")[1] for r in rows] == ["shared", "dev", "prod"]
    assert "| `shared` | 2 | 1 | 2 |" in text
    assert "No plan was produced for: `sit`, `pre-prod`" in text


def test_cli_roundtrip(tmp_path):
    f = tmp_path / "p.json"
    f.write_text(json.dumps(PLAN))
    done = run(["python3", str(ROOT / "scripts" / "plan_summary.py"), "plan", str(f), "--scope", "sit", "--out", str(tmp_path / "o.md")], {"PATH": "/usr/bin:/bin"})
    assert done.returncode == 0 and (tmp_path / "o.md").read_text() == done.stdout

#!/usr/bin/env python3
"""Turn `terraform show -json tfplan` into a small markdown summary: how many resources are added (+), changed (~)
and destroyed (-), and WHICH ones. The pipelines write it to the job summary (GITHUB_STEP_SUMMARY).

  terraform show -json tfplan > tfplan.json
  python3 scripts/plan_summary.py plan tfplan.json --scope dev          # one scope
  python3 scripts/plan_summary.py combine summaries/                    # the table across scopes (pull request)

A replacement ("-/+": destroy and create again) counts as one + and one -, exactly like Terraform's own
"Plan: 1 to add, 0 to change, 1 to destroy" line. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SCOPES = ["shared", "dev", "sit", "pre-prod", "prod"]  # the order of the pipeline
MARK = {"create": "+", "update": "~", "delete": "-", "replace": "-/+"}


def classify(actions: list[str]) -> str | None:
    """create | update | delete | replace, or None when nothing happens (no-op, read)."""
    acts = set(actions)
    if acts == {"create", "delete"}:
        return "replace"
    if acts == {"create"}:
        return "create"
    if acts == {"update"}:
        return "update"
    if acts == {"delete"}:
        return "delete"
    return None


def counts_and_changes(plan: dict) -> tuple[dict, list[tuple[str, str]]]:
    counts = {"add": 0, "change": 0, "destroy": 0}
    changes: list[tuple[str, str]] = []
    for rc in plan.get("resource_changes") or []:
        kind = classify(rc.get("change", {}).get("actions", []))
        if kind is None:
            continue
        changes.append((kind, rc["address"]))
        if kind in ("create", "replace"):
            counts["add"] += 1
        if kind == "update":
            counts["change"] += 1
        if kind in ("delete", "replace"):
            counts["destroy"] += 1
    return counts, changes


def drifted(plan: dict) -> list[str]:
    """Resources that changed OUTSIDE Terraform (someone clicked in the console): Terraform's `resource_drift`."""
    return [d["address"] for d in plan.get("resource_drift") or [] if d.get("change", {}).get("actions") not in (["no-op"], ["read"])]


def summarize(plan: dict, scope: str, note: str = "", drift: bool = False) -> tuple[dict, str]:
    counts, changes = counts_and_changes(plan)
    outside = drifted(plan)
    lines = [f"<!-- scope={scope} add={counts['add']} change={counts['change']} destroy={counts['destroy']} -->"]
    if drift:
        verdict = "DRIFT" if (changes or outside) else "no drift"
        lines.append(f"### drift · `{scope}` · {verdict}")
    else:
        lines.append(f"### plan · `{scope}`")
    lines.append("")
    lines.append(f"**+ {counts['add']} to add · ~ {counts['change']} to change · - {counts['destroy']} to destroy**")
    if note:
        lines += ["", f"> {note}"]
    if changes:
        lines += ["", "| | resource |", "| --- | --- |"]
        lines += [f"| `{MARK[kind]}` | `{address}` |" for kind, address in changes]
    elif not note:
        lines += ["", "No changes. The real infrastructure matches the code."]
    if outside:
        lines += ["", "Changed outside Terraform (someone edited it by hand):", ""]
        lines += [f"- `{address}`" for address in outside]
    return counts, "\n".join(lines) + "\n"


def combine(directory: Path) -> str:
    """One table over every scope's summary file (<!-- scope=... --> comment on the first line)."""
    rows = {}
    for path in sorted(directory.glob("*.md")):
        m = re.search(r"<!-- scope=(\S+) add=(\d+) change=(\d+) destroy=(\d+) -->", path.read_text(encoding="utf-8"))
        if m:
            rows[m.group(1)] = tuple(int(x) for x in m.groups()[1:])
    out = ["## Terraform plan, every scope", "", "| scope | + add | ~ change | - destroy |", "| --- | ---: | ---: | ---: |"]
    for scope in [s for s in SCOPES if s in rows] + sorted(set(rows) - set(SCOPES)):
        add, change, destroy = rows[scope]
        out.append(f"| `{scope}` | {add} | {change} | {destroy} |")
    missing = [s for s in SCOPES if s not in rows]
    if missing:
        out += ["", "No plan was produced for: " + ", ".join(f"`{s}`" for s in missing) + " (see the failed job)."]
    sections = []
    for scope in [s for s in SCOPES if s in rows] + sorted(set(rows) - set(SCOPES)):
        text = (directory / f"summary-{scope}.md")
        if text.exists():
            sections.append(text.read_text(encoding="utf-8"))
    return "\n".join(out) + "\n\n" + "\n".join(sections)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="summarize one plan (terraform show -json output)")
    p.add_argument("plan_json")
    p.add_argument("--scope", required=True)
    p.add_argument("--note", default="")
    p.add_argument("--drift", action="store_true", help="title it as a drift check")
    p.add_argument("--out", help="also write the markdown to this file")
    c = sub.add_parser("combine", help="one table over a folder of summary-<scope>.md files")
    c.add_argument("directory")
    args = ap.parse_args(argv)

    if args.cmd == "plan":
        plan = json.loads(Path(args.plan_json).read_text(encoding="utf-8"))
        _, md = summarize(plan, args.scope, args.note, args.drift)
        if args.out:
            Path(args.out).write_text(md, encoding="utf-8")
        sys.stdout.write(md)
    else:
        sys.stdout.write(combine(Path(args.directory)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

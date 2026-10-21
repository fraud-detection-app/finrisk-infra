#!/usr/bin/env python3
"""Reads `terraform output -json` of bootstrap/ for scripts/github_bootstrap.sh (kept out of the shell script because
the macOS bash 3.2 cannot parse here-documents inside $( ) reliably).

  outputs_reader.py FILE get <name> [<key> ...]       one value (a string, or JSON for a map/list)
  outputs_reader.py FILE kv <name> <repo-key>         "NAME<TAB>value" lines of a {repo: {NAME: value}} output
  outputs_reader.py FILE envs <repo-key>              the Environment names of one repository, space separated
  outputs_reader.py FILE env-secrets <repo-key>       "ENV<TAB>NAME<TAB>value" lines
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    path, cmd, args = argv[0], argv[1], argv[2:]
    outputs = {k: v["value"] for k, v in json.load(open(path, encoding="utf-8")).items()}

    def need(name: str):
        if name not in outputs:
            sys.exit("terraform output is missing '%s'. Re-apply bootstrap with the current code." % name)
        return outputs[name]

    if cmd == "get":
        value = need(args[0])
        for key in args[1:]:
            try:
                value = value[key]
            except (KeyError, TypeError):
                sys.exit("terraform output '%s' has no '%s'. Re-apply bootstrap with the current code." % (args[0], key))
        print(value if isinstance(value, str) else json.dumps(value))
    elif cmd == "kv":
        for name, value in sorted(need(args[0]).get(args[1], {}).items()):
            print("%s\t%s" % (name, value))
    elif cmd == "envs":
        print(" ".join(need("github_environments")[args[0]]))
    elif cmd == "env-secrets":
        for env, secrets in sorted(need("github_environment_secrets")[args[0]].items()):
            for name, value in sorted(secrets.items()):
                print("%s\t%s\t%s" % (env, name, value))
    else:
        sys.exit("unknown command " + cmd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

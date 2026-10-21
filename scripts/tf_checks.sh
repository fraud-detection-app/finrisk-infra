#!/usr/bin/env bash
# The offline Terraform checks: format, validate, and `terraform test` against a MOCK AWS provider.
# Nothing is created, no AWS account or credentials are needed. This is exactly what the pull request's
# `terraform-checks` job runs.
#
#   bash scripts/tf_checks.sh                  # bootstrap, shared and envs
#   bash scripts/tf_checks.sh envs             # one stack (any of: bootstrap shared envs)
#
# It works in a temporary COPY of the repository, so no .terraform folder, lock-file change or state file lands
# in your checkout (and iCloud never sees them). The copy leaves out everything Terraform and the instructor's real apply
# produce -- *.tfstate*, the saved plan files (`plan`, tfplan*), .terraform/ and .env -- so a live bootstrap/ folder is
# never read, only its .tf and test files. The AWS provider comes from Terraform's plugin cache
# (~/.terraform.d/plugin-cache by default), so a second run needs no download.
#
# Two details worth knowing:
#   - shared/ and envs/ keep their state in S3 (backend.tf). The copy drops backend.tf, so the tests use local state.
#   - envs/ has a workspace guard (workspace must equal env), and `terraform test` runs in the CURRENT workspace.
#     So each environment's test file runs in a workspace of the same name, and the guard test runs in "dev".
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
STACKS=("$@")
if [ "${#STACKS[@]}" -eq 0 ]; then STACKS=(bootstrap shared envs); fi

command -v terraform >/dev/null || { echo "terraform is not installed (https://developer.hashicorp.com/terraform/install)" >&2; exit 1; }

export TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1 NO_COLOR=1
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

work="$(mktemp -d "${TMPDIR:-/tmp}/finrisk-infra-checks.XXXXXX")"
trap 'rm -rf "$work"' EXIT

group() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$1"; else printf '\n== %s\n' "$1"; fi; }
endgroup() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }

for stack in "${STACKS[@]}"; do
  case "$stack" in bootstrap|shared|envs) ;; *) echo "unknown stack '$stack' (bootstrap, shared or envs)" >&2; exit 2 ;; esac
  mkdir -p "$work/$stack"
  (cd "$here/$stack" && tar cf - --exclude .terraform --exclude '*.tfstate' --exclude '*.tfstate.*' --exclude plan --exclude tfplan --exclude 'tfplan.json' --exclude '*.tfplan' --exclude '.env' --exclude 'oidc_subjects.auto.tfvars.json' .) | (cd "$work/$stack" && tar xf -)
  rm -f "$work/$stack/backend.tf"

  group "$stack: terraform fmt -check"
  terraform -chdir="$work/$stack" fmt -check -recursive -diff
  endgroup

  group "$stack: terraform init + validate"
  terraform -chdir="$work/$stack" init -backend=false -input=false >/dev/null
  terraform -chdir="$work/$stack" validate
  endgroup

  if [ "$stack" = "envs" ]; then
    for env in dev sit pre-prod prod; do
      group "envs: terraform test, workspace $env"
      terraform -chdir="$work/$stack" workspace new "$env" >/dev/null
      terraform -chdir="$work/$stack" test -filter="tests/$env.tftest.hcl"
      endgroup
    done
    group "envs: terraform test, the workspace guard (workspace dev)"
    terraform -chdir="$work/$stack" workspace select dev >/dev/null
    terraform -chdir="$work/$stack" test -filter="tests/guard.tftest.hcl"
    endgroup
  else
    group "$stack: terraform test"
    terraform -chdir="$work/$stack" test
    endgroup
  fi
done

echo
echo "All Terraform checks passed: ${STACKS[*]}"

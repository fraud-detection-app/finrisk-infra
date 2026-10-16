#!/usr/bin/env bash
# Configure ALL FOUR GitHub repositories of the course from what `terraform apply` in bootstrap/ just built.
#
#   bash scripts/github_bootstrap.sh <org>                 # DRY RUN: only prints what it would do (calls no gh command)
#   bash scripts/github_bootstrap.sh <org> --apply         # does it (needs `gh auth login` with admin on the org's repos)
#
# Run it ONCE, after bootstrap's `terraform apply` and after the four repositories exist (public: a free organisation has
# Environments and rulesets only on public repositories). Running it again is safe: variables and secrets are overwritten
# with the same values, Environments and rulesets are updated in place.
#
# ------------------------------------------------------------------------------------------------------------------
# THE CONTRACT with the other three repositories (names the workflows read; change one here and there together)
#
#   Required status checks of ruleset `protect-main` (job names in the repo's CI workflow; the ruleset needs the
#   exact string GitHub shows for the check, so these jobs are plain jobs, not matrix jobs):
#
#     repository          required checks (job ids in .github/workflows/)
#     finrisk-infra       plan  terraform-checks              infra-ci.yml
#     finrisk-app         test  terraform                     ci.yml
#     finrisk-ml          test                                ml-ci.yml
#     finrisk-knowledge   kb-check                            kb-ci.yml
#
#   Environments (all: deployment branch policy `main` only; R = a required reviewer, you, self-review allowed):
#
#     finrisk-infra       infra-shared (R)  infra-dev  infra-sit  infra-pre-prod (R)  infra-prod (R)
#     finrisk-app         dev  sit  pre-prod (R)  prod (R)
#     finrisk-ml          ml  model-approval (R)  dev  sit  pre-prod (R)  prod (R)
#     finrisk-knowledge   dev  sit  pre-prod (R)  prod (R)
#
#   Repository VARIABLES (no account id)                      Repository SECRETS (each contains the account id)
#     infra      AWS_REGION                                      TF_STATE_BUCKET  AWS_PLAN_ROLE_ARN  AWS_DRIFT_ROLE_ARN
#     app        AWS_REGION                                      TF_STATE_BUCKET  AWS_BUILD_ROLE_ARN  ECR_REPOSITORY
#     ml         AWS_REGION                                      (none: the ML names come from SSM /finrisk/shared/*)
#     knowledge  AWS_REGION                                      KB_BUCKET  AWS_KB_BUILD_ROLE_ARN
#
#   ONE naming rule: a job WITH `environment:` reads secrets.AWS_ROLE_ARN -- an ENVIRONMENT secret holding that
#   Environment's role for that repository (set below for every Environment above). A job WITHOUT an environment (a pull-request
#   plan, a build on main) reads a REPOSITORY secret named after its role: AWS_PLAN_ROLE_ARN, AWS_DRIFT_ROLE_ARN,
#   AWS_BUILD_ROLE_ARN, AWS_KB_BUILD_ROLE_ARN.
# ------------------------------------------------------------------------------------------------------------------
#
# The values come from `terraform output -json` (bootstrap/): the script only sends what Terraform says, so a name
# that is missing here but present there (or the other way round) shows up as an error, not as a silent gap.
#
# Why secrets for ARNs and bucket names? Each contains the AWS account id and the repositories are PUBLIC, so their logs
# are world-readable. GitHub hides a secret everywhere in a log; it does not hide a variable. Nothing here is secret in the
# password sense: AWS trusts a short-lived GitHub token (OIDC), and a role ARN alone grants nothing without that trust.
# Every command this script PRINTS has 12-digit account ids replaced by <account-id>; secret values are sent on stdin,
# never on a command line (so `ps` cannot show them either).
#
# Options:
#   --apply               do it (default: dry run)
#   --bootstrap-dir DIR   where `terraform output` runs (default: bootstrap/ of this repository; after Step 1 of the
#                         README that is ~/terraform-labs/finrisk-bootstrap)
#   --outputs-file FILE   read `terraform output -json` from FILE instead of running terraform (offline use, tests)
#   --reviewer-ids 1,2    GitHub numeric USER ids for the reviewers (default: your own, looked up with `gh api user`)
#   --approvals N         approving reviews a pull request needs before merge (default 0: a one-person team cannot
#                         approve its own pull request; the required checks still apply)
#   --admin-bypass        let repository admins bypass the rulesets (emergency door; default: nobody bypasses)
#   --only a,b            only these repository keys (infra, app, ml, knowledge)
#
# Works with the bash 3.2 that ships with macOS. Needs python3 (to read JSON) and, with --apply, gh.
set -euo pipefail

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

ORG=""
APPLY=0
BOOTSTRAP_DIR=""
OUTPUTS_FILE=""
REVIEWER_IDS=""
APPROVALS=0
ADMIN_BYPASS=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)          APPLY=1 ;;
    --bootstrap-dir)  shift; BOOTSTRAP_DIR="${1:?--bootstrap-dir needs a folder}" ;;
    --outputs-file)   shift; OUTPUTS_FILE="${1:?--outputs-file needs a file}" ;;
    --reviewer-ids)   shift; REVIEWER_IDS="${1:?--reviewer-ids needs a list like 123,456}" ;;
    --approvals)      shift; APPROVALS="${1:?--approvals needs a number}" ;;
    --admin-bypass)   ADMIN_BYPASS=1 ;;
    --only)           shift; ONLY="${1:?--only needs a list like infra,app}" ;;
    -h|--help)        usage 0 ;;
    -*)               echo "unknown option: $1" >&2; usage ;;
    *)                if [ -z "$ORG" ]; then ORG="$1"; else echo "unexpected argument: $1" >&2; usage; fi ;;
  esac
  shift
done

[ -n "$ORG" ] || usage
if ! [[ "$ORG" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
  echo "'$ORG' is not a GitHub organisation name (letters, digits and hyphens)." >&2; exit 2
fi
if ! [[ "$APPROVALS" =~ ^[0-9]+$ ]]; then echo "--approvals must be a number" >&2; exit 2; fi
command -v python3 >/dev/null || { echo "python3 is needed to read the Terraform outputs." >&2; exit 1; }
if [ "$APPLY" = 1 ]; then command -v gh >/dev/null || { echo "gh (GitHub CLI) is needed with --apply: https://cli.github.com" >&2; exit 1; }; fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$BOOTSTRAP_DIR" ] || BOOTSTRAP_DIR="$ROOT/bootstrap"

# ------------------------------------------------------------------ the Terraform outputs
OUT="$(mktemp "${TMPDIR:-/tmp}/finrisk-outputs.XXXXXX")"
trap 'rm -f "$OUT"' EXIT
if [ -n "$OUTPUTS_FILE" ]; then
  cp "$OUTPUTS_FILE" "$OUT"
else
  command -v terraform >/dev/null || { echo "terraform is not installed (or pass --outputs-file)." >&2; exit 1; }
  if ! terraform -chdir="$BOOTSTRAP_DIR" output -json > "$OUT" 2>/dev/null || [ ! -s "$OUT" ] || [ "$(tr -d '[:space:]' < "$OUT")" = "{}" ]; then
    echo "No outputs from $BOOTSTRAP_DIR. Apply bootstrap first (once, as an admin user): see README.md, Step 1." >&2
    exit 1
  fi
fi

# jget <output> [<key>...]: one value from the Terraform outputs
READER="$ROOT/scripts/outputs_reader.py"
jget() { python3 "$READER" "$OUT" get "$@"; }

TRUSTED="$(jget github_org)"
if [ "$TRUSTED" != "$ORG" ]; then
  echo "WARNING: the AWS roles trust the organisation '$TRUSTED' but you are configuring '$ORG'." >&2
  echo "         GitHub's token says repo:<org>/<repo> exactly (case matters); AWS will refuse any other. Fix with:" >&2
  echo "         terraform -chdir=$BOOTSTRAP_DIR apply -var github_org=$ORG" >&2
  if [ "$APPLY" = 1 ]; then echo "Stopping (nothing was changed)." >&2; exit 1; fi
fi

# ------------------------------------------------------------------ the plan of work (from the outputs)
repo_name() { jget repositories "$1"; }
KEYS="infra app ml knowledge"
if [ -n "$ONLY" ]; then
  KEYS="$(printf '%s' "$ONLY" | tr ',' ' ')"
  for k in $KEYS; do case "$k" in infra|app|ml|knowledge) ;; *) echo "--only: '$k' is not infra, app, ml or knowledge" >&2; exit 2 ;; esac; done
fi

# required status checks of ruleset protect-main -- see the table at the top
checks_for() {
  case "$1" in
    infra)     echo "plan terraform-checks" ;;
    app)       echo "test terraform" ;;
    ml)        echo "test" ;;
    knowledge) echo "kb-check" ;;
  esac
}

# Environments that need a required reviewer
needs_reviewer() {
  case "$1:$2" in
    infra:infra-shared|infra:infra-pre-prod|infra:infra-prod) return 0 ;;
    ml:model-approval) return 0 ;;
    app:pre-prod|app:prod|ml:pre-prod|ml:prod|knowledge:pre-prod|knowledge:prod) return 0 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------ helpers
if [ "$APPLY" = 1 ]; then echo "== APPLY: changing the repositories of $ORG"; else echo "== DRY RUN for $ORG: printing the commands, changing nothing (add --apply to run them)"; fi

# hide_ids: what is PRINTED never shows an AWS account id (any run of 12 or more digits); what is RUN uses the real value
hide_ids() { sed -E 's/[0-9]{12,}/<account-id>/g'; }

step() { printf '\n-- %s\n' "$1"; }

# api <METHOD> <path> <json>: the JSON body is sent on stdin
api() {
  printf "+ printf '%%s' '%s' | gh api -X %s %s --input -\n" "$3" "$1" "$2" | hide_ids
  if [ "$APPLY" = 1 ]; then printf '%s' "$3" | gh api -X "$1" "$2" --input - > /dev/null; fi
}

# put_var <repo> <name> <value>
put_var() {
  printf '+ gh variable set %s --repo %s --body %q\n' "$2" "$1" "$3" | hide_ids
  if [ "$APPLY" = 1 ]; then gh variable set "$2" --repo "$1" --body "$3" < /dev/null; fi
}

# put_secret <repo> <name> <value> [environment]: the value goes on stdin
put_secret() {
  local env_flag=""
  if [ -n "${4:-}" ]; then env_flag=" --env $4"; fi
  printf "+ printf '%%s' %q | gh secret set %s --repo %s%s\n" "$3" "$2" "$1" "$env_flag" | hide_ids
  if [ "$APPLY" = 1 ]; then
    if [ -n "${4:-}" ]; then printf '%s' "$3" | gh secret set "$2" --repo "$1" --env "$4"; else printf '%s' "$3" | gh secret set "$2" --repo "$1"; fi
  fi
}

# ------------------------------------------------------------------ reviewers
REVIEWERS_JSON="[]"
if [ "$APPLY" = 1 ] && [ -z "$REVIEWER_IDS" ]; then REVIEWER_IDS="$(gh api user --jq .id)"; fi
if [ -n "$REVIEWER_IDS" ]; then
  REVIEWERS_JSON=""
  IFS=',' read -r -a IDS <<< "$REVIEWER_IDS"
  for id in "${IDS[@]}"; do
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "reviewer id '$id' is not a number (find yours: gh api user --jq .id)" >&2; exit 2; }
    REVIEWERS_JSON="${REVIEWERS_JSON:+$REVIEWERS_JSON,}{\"type\":\"User\",\"id\":$id}"
  done
  REVIEWERS_JSON="[$REVIEWERS_JSON]"
else
  REVIEWERS_JSON='[{"type":"User","id":"<your-github-user-id: gh api user --jq .id>"}]' # dry run only
fi

if [ "$ADMIN_BYPASS" = 1 ]; then
  BYPASS='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]' # 5 = the repository Admin role
else
  BYPASS='[]'
fi
PR_RULE="{\"type\":\"pull_request\",\"parameters\":{\"required_approving_review_count\":$APPROVALS,\"dismiss_stale_reviews_on_push\":false,\"require_code_owner_review\":false,\"require_last_push_approval\":false,\"required_review_thread_resolution\":false}}"

# ensure_ruleset <repo> <name> <json>: update the ruleset with that name, or create it
ensure_ruleset() {
  local repo="$1" name="$2" json="$3" id=""
  if [ "$APPLY" = 1 ]; then
    id="$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name==\"$name\") | .id")"
  fi
  if [ -n "$id" ]; then api PUT "repos/$repo/rulesets/$id" "$json"; else api POST "repos/$repo/rulesets" "$json"; fi
}

# ------------------------------------------------------------------ one repository at a time
configure_repo() {
  local key="$1" name repo
  name="$(repo_name "$key")"
  repo="$ORG/$name"
  printf '\n==================== %s (%s) ====================\n' "$repo" "$key"

  step "1/6  Actions: the default token can only read the repository"
  api PUT "repos/$repo/actions/permissions/workflow" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'

  step "2/6  Environments (a reviewer where marked; deployment branch policy: main only)"
  local envs env reviewers
  envs="$(python3 "$READER" "$OUT" envs "$key")"
  for env in $envs; do
    if needs_reviewer "$key" "$env"; then reviewers="$REVIEWERS_JSON"; else reviewers="[]"; fi
    # custom_branch_policies:true = "only the branches I list next". prevent_self_review:false = a one-person team can approve itself.
    api PUT "repos/$repo/environments/$env" "{\"wait_timer\":0,\"prevent_self_review\":false,\"reviewers\":$reviewers,\"deployment_branch_policy\":{\"protected_branches\":false,\"custom_branch_policies\":true}}"
    if [ "$APPLY" = 1 ] && gh api "repos/$repo/environments/$env/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx "main"; then
      echo "  $env <- main (already there)"
    else
      api POST "repos/$repo/environments/$env/deployment-branch-policies" '{"name":"main","type":"branch"}'
    fi
  done

  step "3/6  Repository variables (plain names: no account id in them)"
  local n v
  while IFS="$(printf '\t')" read -r n v; do
    if [ -n "$n" ]; then put_var "$repo" "$n" "$v"; fi
  done < <(python3 "$READER" "$OUT" kv github_repo_variables "$key")

  step "4/6  Repository secrets (every value contains the account id, so GitHub must hide it in the public log)"
  while IFS="$(printf '\t')" read -r n v; do
    if [ -n "$n" ]; then put_secret "$repo" "$n" "$v"; fi
  done < <(python3 "$READER" "$OUT" kv github_repo_secrets "$key")

  step "5/6  Environment secrets: each Environment gets its own role"
  local e
  while IFS="$(printf '\t')" read -r e n v; do
    if [ -n "$e" ]; then put_secret "$repo" "$n" "$v" "$e"; fi
  done < <(python3 "$READER" "$OUT" env-secrets "$key")

  step "6/6  Ruleset protect-main (pull request + required checks, no force-push, no deletion)"
  local contexts="" c
  for c in $(checks_for "$key"); do contexts="${contexts:+$contexts,}{\"context\":\"$c\"}"; done
  ensure_ruleset "$repo" "protect-main" "{\"name\":\"protect-main\",\"target\":\"branch\",\"enforcement\":\"active\",\"bypass_actors\":$BYPASS,\"conditions\":{\"ref_name\":{\"include\":[\"refs/heads/main\"],\"exclude\":[]}},\"rules\":[{\"type\":\"deletion\"},{\"type\":\"non_fast_forward\"},$PR_RULE,{\"type\":\"required_status_checks\",\"parameters\":{\"strict_required_status_checks_policy\":false,\"required_status_checks\":[$contexts]}}]}"
}

for key in $KEYS; do configure_repo "$key"; done

# ------------------------------------------------------------------ what next
cat <<NEXT

== Done. Still by hand (GitHub has no API for these):
   - Each repository must be PUBLIC (a free organisation has Environments and rulesets only on public repositories).
   - Push the first commit of each repository BEFORE the first --apply if you can: protect-main blocks direct pushes
     to main (a repository's first push can then only come through a pull request).
   - Check the result:  gh api repos/$ORG/<repo>/environments --jq '.environments[].name'
                        gh variable list --repo $ORG/<repo> ; gh secret list --repo $ORG/<repo>
NEXT

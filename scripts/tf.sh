#!/usr/bin/env bash
# One place that knows how a SCOPE maps to a Terraform folder, a state key, a workspace and a tfvars file.
# The three workflows (infra-ci, infra-deliver, drift) call it step by step, so what runs in the pipeline is what
# you can run by hand.
#
#   bash scripts/tf.sh init  <scope>      connect to the state bucket
#   bash scripts/tf.sh plan  <scope>      plan -out tfplan, then write the + ~ - summary
#   bash scripts/tf.sh apply <scope>      apply EXACTLY the saved plan (terraform apply tfplan)
#
#   scope        folder   state object (in the bucket)         workspace   tfvars
#   shared       shared/  infra/shared.tfstate                 (default)   -
#   dev          envs/    env:/dev/infra/env.tfstate           dev         dev.tfvars
#   sit          envs/    env:/sit/infra/env.tfstate           sit         sit.tfvars
#   pre-prod     envs/    env:/pre-prod/infra/env.tfstate      pre-prod    pre-prod.tfvars
#   prod         envs/    env:/prod/infra/env.tfstate          prod        prod.tfvars
#
# Environment variables:
#   STATE_BUCKET     the state bucket (a GitHub secret; required)         AWS_REGION   (a GitHub variable; required)
#   TF_READ_ONLY=1   pull request plan: never lock, never create a workspace (the plan role cannot write)
#   TF_DRIFT=1       nightly check: plan -detailed-exitcode; exit 2 = something changed -> the job fails
#   GITHUB_STEP_SUMMARY, SUMMARY_FILE   where the markdown summary goes (default: the screen)
#
# Works with the bash 3.2 that ships with macOS.
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

CMD="${1:-}"; SCOPE="${2:-}"
[ -n "$CMD" ] && [ -n "$SCOPE" ] || usage

case "$SCOPE" in
  shared)
    DIR=shared; KEY=infra/shared.tfstate; WS=""; VARFILE="" ;;
  dev|sit|pre-prod|prod)
    DIR=envs; KEY=infra/env.tfstate; WS="$SCOPE"; VARFILE="$SCOPE.tfvars" ;;
  *)
    echo "unknown scope '$SCOPE' (shared, dev, sit, pre-prod or prod)" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
READ_ONLY="${TF_READ_ONLY:-0}"
DRIFT="${TF_DRIFT:-0}"
tf() { terraform -chdir="$DIR" "$@"; }

do_init() {
  : "${STATE_BUCKET:?STATE_BUCKET is not set (the GitHub secret TF_STATE_BUCKET)}"
  : "${AWS_REGION:?AWS_REGION is not set (the GitHub variable AWS_REGION)}"
  tf init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=$KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true"
}

# Which workspace? One workspace = one environment = one state file. A guard in envs/main.tf double-checks it.
select_workspace() {
  [ -n "$WS" ] || return 0
  if [ "$READ_ONLY" != 1 ]; then
    tf workspace select -or-create "$WS"
    return 0
  fi
  # A pull request may run before the first apply created this workspace, and the plan role cannot create it.
  # "workspace list" FAILS on a real error (access denied), so a missing workspace is told apart from a broken login.
  local listing
  listing="$(tf workspace list)"
  if printf '%s\n' "$listing" | grep -Eq "^[* ] +$WS\$"; then
    tf workspace select "$WS"
  else
    echo "NOTE: workspace '$WS' is not in the state bucket yet (first apply pending). Planning against an EMPTY state." >&2
    NOTE="First plan: $WS has not been applied yet, so every resource shows as added."
    rm -f "$DIR/backend.tf"
    tf init -input=false -reconfigure -backend=false >/dev/null
    tf workspace new "$WS"
  fi
}

NOTE=""
do_plan() {
  select_workspace
  local flags=(-input=false -out=tfplan)
  if [ "$READ_ONLY" = 1 ]; then flags+=(-lock=false); else flags+=(-lock-timeout=5m); fi
  if [ "$DRIFT" = 1 ]; then flags+=(-detailed-exitcode); fi
  if [ -n "$VARFILE" ]; then flags+=("-var-file=$VARFILE"); fi

  local code=0
  tf plan "${flags[@]}" || code=$?
  if [ "$code" = 1 ]; then echo "terraform plan failed" >&2; exit 1; fi

  # + ~ - counts and the list of addresses, for the job summary
  tf show -json tfplan > "$DIR/tfplan.json"
  local args=(plan "$DIR/tfplan.json" --scope "$SCOPE")
  if [ -n "$NOTE" ]; then args+=(--note "$NOTE"); fi
  if [ "$DRIFT" = 1 ]; then args+=(--drift); fi
  local md; md="$(python3 scripts/plan_summary.py "${args[@]}")"
  printf '%s\n' "$md"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$md" >> "$GITHUB_STEP_SUMMARY"; fi
  if [ -n "${SUMMARY_FILE:-}" ]; then printf '%s\n' "$md" > "$SUMMARY_FILE"; fi

  if [ "$code" = 2 ] && [ "$DRIFT" = 1 ]; then
    echo "::error title=Drift in $SCOPE::The real infrastructure differs from the code. See the job summary for the addresses."
    exit 2
  fi
}

do_apply() {
  [ -f "$DIR/tfplan" ] || { echo "no saved plan: run 'bash scripts/tf.sh plan $SCOPE' first (apply uses exactly that plan)" >&2; exit 1; }
  tf apply -input=false -lock-timeout=5m tfplan
}

case "$CMD" in
  init)  do_init ;;
  plan)  do_plan ;;
  apply) do_apply ;;
  *)     usage ;;
esac

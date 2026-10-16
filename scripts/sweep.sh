#!/usr/bin/env bash
# sweep.sh -- is anything of the finrisk course still in this AWS account?  READ-ONLY.
#
#   bash scripts/sweep.sh                    # the Region is $AWS_REGION (default ap-southeast-2)
#   SWEEP_KEEP_OIDC=1 bash scripts/sweep.sh  # the GitHub login provider is not ours (week 13a made it): list it, do not count it
#
# It only lists (aws ... list-* / describe-* / get-*): nothing is created, changed or deleted. For every kind of
# resource the four repositories can create it prints one row: how many were found, and their names (a 12-digit
# AWS account id inside a name is shown as <account-id>). The last line says how many are left:
#
#   TOTAL 0 left      exit 0   the account is clean
#   TOTAL <n> left    exit 1   n resources still exist (and still cost money, if they are Express services)
#
# If a check itself fails (an expired sign-in, a missing permission) the row says so, the sweep carries on, and the last
# line says "NOT proven clean" (exit 1). If you are not signed in at all it stops with exit 2.
#
# What is looked at, and how it is matched (everything by the course prefix `finrisk`):
#   ECR repositories finrisk*  - S3 buckets finrisk-* (S3 is global: any Region)  - Lambda functions finrisk*
#   ECS services: EVERY service in every cluster of the Region (an Express Mode service is an ordinary ECS service named
#     finrisk-<env>, and any service bills)  - ECS clusters finrisk*
#   Load balancers and target groups named finrisk* or ecs-*  (ECS Express Mode creates its own load balancer and names it
#     itself, so the names starting `ecs-` are counted; the CLI lists every other load balancer of the account too, but
#     those are not ours and not counted)
#   IAM roles and customer-managed policies finrisk-* (IAM is global)  - the GitHub OIDC provider
#   SSM parameters under /finrisk  - CloudWatch log groups /app/finrisk-* and /aws/lambda/finrisk-*
#   SageMaker training jobs InProgress or Stopping named finrisk*  - SageMaker model package groups finrisk-*
# Not counted: Budgets, service-linked roles (free, the next Express service needs them), SageMaker's history of FINISHED
# training jobs and its log group /aws/sagemaker/TrainingJobs (a few cents).
#
# Works with the bash 3.2 that ships with macOS (no mapfile, no ${x,,}, no associative arrays). Needs the aws CLI and python3.
set -uo pipefail # not -e: one failing check must not stop the others

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-2}}"
export AWS_PAGER=""
KEEP_OIDC="${SWEEP_KEEP_OIDC:-0}"

command -v aws >/dev/null 2>&1 || { echo "sweep: the aws CLI is not installed." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "sweep: python3 is needed to read the aws answers." >&2; exit 2; }

ERR="$(mktemp "${TMPDIR:-/tmp}/finrisk-sweep.XXXXXX")"
trap 'rm -f "$ERR"' EXIT

# What is PRINTED never shows an account id.
mask() { sed -E 's/[0-9]{12}/<account-id>/g'; }

if ! aws sts get-caller-identity --region "$REGION" --query Arn --output text >/dev/null 2>"$ERR"; then
  echo "sweep: cannot reach AWS ($(head -n 1 "$ERR" | mask)). Sign in first: aws login" >&2
  exit 2
fi

# list_names <key> <field> <regex> <aws command...>
#   Runs ONE read-only aws call (JSON). In the list found under <key> (empty key = the answer itself is the list) it keeps
#   <field> of each item (empty field = the item is a string) when that matches <regex>, one per line.
#   Returns 1 when the aws call fails; the CLI's message is left in $ERR.
list_names() {
  local key="$1" field="$2" regex="$3" out
  shift 3
  if ! out="$("$@" --output json 2>"$ERR")"; then return 1; fi
  printf '%s' "$out" | python3 -c '
import json, re, sys
key, field, regex = sys.argv[1:4]
data = json.load(sys.stdin)
items = data.get(key, []) if key else data
for item in items or []:
    value = item.get(field, "") if field else item
    if isinstance(value, str) and re.search(regex, value):
        print(value)
' "$key" "$field" "$regex" 2>"$ERR"
}

TOTAL=0
FAILED=0

# row <label> <status of the check> <names, one per line> [counted: 1|0]
row() {
  local label="$1" status="$2" names="$3" counted="${4:-1}" n=0 list="" line
  if [ "$status" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    printf '%-38s %s\n' "$label" "?  could not check: $(head -n 1 "$ERR" | mask)"
    return
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    list="$list $line"
  done <<EOF
$names
EOF
  if [ "$counted" = 1 ]; then TOTAL=$((TOTAL + n)); fi
  if [ "$n" -eq 0 ]; then
    printf '%-38s %s\n' "$label" "0"
  else
    printf '%-38s %s %s\n' "$label" "$n" "$(printf '%s' "$list" | mask)$([ "$counted" = 1 ] || printf '   (not counted)')"
  fi
}

# check <label> <key> <field> <regex> <aws command...>
check() {
  local label="$1" key="$2" field="$3" regex="$4" names status
  shift 4
  names="$(list_names "$key" "$field" "$regex" "$@")"
  status=$?
  row "$label" "$status" "$names"
}

echo "sweep: finrisk resources in $REGION (read-only; IAM and S3 are account-wide)"
echo

check "ECR repositories"              repositories    repositoryName     '^finrisk'         aws ecr describe-repositories --region "$REGION"
check "S3 buckets"                    Buckets         Name               '^finrisk-'        aws s3api list-buckets --region "$REGION"
check "Lambda functions"              Functions       FunctionName       '^finrisk'         aws lambda list-functions --region "$REGION"

# ECS: every service of every cluster. An Express Mode service is a plain ECS service in a cluster (usually `default`).
clusters="$(list_names clusterArns "" '.' aws ecs list-clusters --region "$REGION")"
cluster_status=$?
services=""
service_status=$cluster_status
if [ "$cluster_status" -eq 0 ]; then
  while IFS= read -r arn; do
    [ -n "$arn" ] || continue
    cluster="${arn##*/}"
    found="$(list_names serviceArns "" '.' aws ecs list-services --cluster "$cluster" --region "$REGION")"
    service_status=$?
    [ "$service_status" -eq 0 ] || break
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      services="${services}${cluster}/${svc##*/}
"
    done <<EOF
$found
EOF
  done <<EOF
$clusters
EOF
fi
row "ECS services (Express Mode too)" "$service_status" "$services"

fin_clusters=""
if [ "$cluster_status" -eq 0 ]; then
  while IFS= read -r arn; do
    case "${arn##*/}" in finrisk*) fin_clusters="${fin_clusters}${arn##*/}
" ;; esac
  done <<EOF
$clusters
EOF
fi
row "ECS clusters" "$cluster_status" "$fin_clusters"

# Load balancers and target groups: ECS Express Mode names its own, starting `ecs-`.
check "Load balancers (finrisk*, ecs-*)" LoadBalancers LoadBalancerName '^(finrisk|ecs-)' aws elbv2 describe-load-balancers --region "$REGION"
check "Target groups (finrisk*, ecs-*)"  TargetGroups  TargetGroupName  '^(finrisk|ecs-)' aws elbv2 describe-target-groups --region "$REGION"

check "IAM roles"                     Roles           RoleName           '^finrisk-'        aws iam list-roles
check "IAM policies (customer)"       Policies        PolicyName         '^finrisk-'        aws iam list-policies --scope Local

names="$(list_names OpenIDConnectProviderList Arn 'token\.actions\.githubusercontent\.com' aws iam list-open-id-connect-providers)"
status=$?
if [ "$KEEP_OIDC" = 1 ]; then row "GitHub OIDC provider" "$status" "$names" 0; else row "GitHub OIDC provider" "$status" "$names"; fi

check "SSM parameters /finrisk"       Parameters      Name               '^/finrisk'        aws ssm get-parameters-by-path --path /finrisk --recursive --region "$REGION"
check "Log groups /app/finrisk-*"     logGroups       logGroupName       '^/app/finrisk-'   aws logs describe-log-groups --log-group-name-prefix /app/finrisk- --region "$REGION"
check "Log groups /aws/lambda/finrisk-*" logGroups    logGroupName       '^/aws/lambda/finrisk-' aws logs describe-log-groups --log-group-name-prefix /aws/lambda/finrisk- --region "$REGION"

# Training jobs that are still billing: InProgress, or Stopping.
jobs=""
jobs_status=0
for state in InProgress Stopping; do
  found="$(list_names TrainingJobSummaries TrainingJobName '^finrisk' aws sagemaker list-training-jobs --status-equals "$state" --name-contains finrisk --region "$REGION")"
  s=$?
  if [ "$s" -ne 0 ]; then jobs_status=$s; break; fi
  [ -z "$found" ] || jobs="${jobs}${found}
"
done
row "SageMaker training jobs running" "$jobs_status" "$jobs"
check "SageMaker model package groups" ModelPackageGroupSummaryList ModelPackageGroupName '^finrisk-' aws sagemaker list-model-package-groups --name-contains finrisk --region "$REGION"

echo
if [ "$FAILED" -gt 0 ]; then
  echo "TOTAL $TOTAL left, but $FAILED check(s) could not run: NOT proven clean"
  exit 1
fi
echo "TOTAL $TOTAL left"
if [ "$TOTAL" -eq 0 ]; then exit 0; fi
exit 1

#!/usr/bin/env bash
# Ask GitHub what the OIDC `sub` of each of the four repositories starts with, and hand it to Terraform.  READ-ONLY.
#
#   bash scripts/oidc_subjects.sh <org>                          # print the four prefixes, write the file in this folder
#   bash scripts/oidc_subjects.sh <org> --out ~/terraform-labs/finrisk-bootstrap
#
# Why: since 15 July 2026 every NEW repository uses an IMMUTABLE subject in its Actions token. The `sub` is then
#
#   repo:fraud-detection-app@343247080/finrisk-infra@1422750317:environment:infra-shared
#        \_________________ prefix _________________/ \_______ suffix (the job) _______/
#
# with the numeric ids of the organisation and of the repository inside the prefix (the ids are public, not secrets), and
# there is no setting to switch that off. bootstrap/ trusts an EXACT sub, so it needs the prefix of each repository,
# and the prefix exists only after the repository does: create the four (empty) repositories first, then run this.
#
# What it does: four `gh api repos/<org>/<name>/actions/oidc/customization/sub --jq .sub_claim_prefix` calls (GET; nothing
# is changed on GitHub), prints the prefixes, and writes
#
#   <DIR>/oidc_subjects.auto.tfvars.json      {"sub_prefixes": {"infra": "...", "app": "...", "ml": "...", "knowledge": "..."}}
#
# Terraform loads any *.auto.tfvars.json in its folder by itself, so `terraform plan` in <DIR> needs no -var-file.
# Run it again after you delete and re-create a repository (or rename the organisation): the ids change, and so must the roles.
# A repository that reports no prefix (created before the change) gets the classic `repo:<org>/<name>`.
#
# Options:
#   --out DIR         the folder to write into; it must exist (default: the current folder). Use the bootstrap folder.
#   --repos LIST      repository names if they are not the course's: infra=finrisk-infra,app=finrisk-app,ml=finrisk-ml,
#                     knowledge=finrisk-knowledge (same as the `repos` variable of bootstrap/). Give only the ones that differ.
#
# Needs gh (signed in; the plain `repo` scope is enough). Works with the bash 3.2 that ships with macOS.
set -euo pipefail

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
die() { echo "oidc_subjects: $1" >&2; exit "${2:-1}"; }

ORG=""
OUT_DIR="."
REPOS_ARG=""
NAME_infra="finrisk-infra"
NAME_app="finrisk-app"
NAME_ml="finrisk-ml"
NAME_knowledge="finrisk-knowledge"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --out) [ $# -ge 2 ] || die "--out needs a folder" 2; OUT_DIR="$2"; shift 2 ;;
    --out=*) OUT_DIR="${1#--out=}"; shift ;;
    --repos) [ $# -ge 2 ] || die "--repos needs a list like infra=finrisk-infra,app=finrisk-app" 2; REPOS_ARG="$2"; shift 2 ;;
    --repos=*) REPOS_ARG="${1#--repos=}"; shift ;;
    -*) die "unknown option $1" 2 ;;
    *) [ -z "$ORG" ] || die "only one organisation, got '$ORG' and '$1'" 2; ORG="$1"; shift ;;
  esac
done

[ -n "$ORG" ] || usage
case "$ORG" in *[!A-Za-z0-9-]*|-*|*-) die "'$ORG' is not a GitHub organisation name (letters, digits and hyphens)" 2 ;; esac

if [ -n "$REPOS_ARG" ]; then
  OLD_IFS="$IFS"; IFS=','
  for pair in $REPOS_ARG; do
    key="${pair%%=*}"; name="${pair#*=}"
    case "$key" in infra|app|ml|knowledge) ;; *) IFS="$OLD_IFS"; die "--repos: unknown key '$key' (infra, app, ml, knowledge)" 2 ;; esac
    case "$name" in ""|"$pair"|*[!A-Za-z0-9._-]*) IFS="$OLD_IFS"; die "--repos: '$pair' is not key=repository-name" 2 ;; esac
    eval "NAME_$key=\$name"
  done
  IFS="$OLD_IFS"
fi

[ -d "$OUT_DIR" ] || die "the folder '$OUT_DIR' does not exist. Copy bootstrap/ there first (README, step 2), or pass --out DIR." 2
command -v gh >/dev/null 2>&1 || die "the gh CLI is not installed (https://cli.github.com), or not on PATH." 2

PREFIX_RE='^repo:[A-Za-z0-9-]+(@[0-9]+)?/[A-Za-z0-9._-]+(@[0-9]+)?$'

echo "Reading the OIDC subject prefix of the four repositories of '$ORG' (GET only; nothing is changed)."
missing=0
missing_list=""
bad=0
json=""
for key in infra app ml knowledge; do
  eval "name=\$NAME_$key"
  err="$(mktemp "${TMPDIR:-/tmp}/finrisk-oidc.XXXXXX")"
  if prefix="$(gh api "repos/$ORG/$name/actions/oidc/customization/sub" --jq .sub_claim_prefix 2>"$err")"; then
    rm -f "$err"
  else
    echo "  $key: cannot read $ORG/$name: $(head -n 1 "$err")" >&2
    rm -f "$err"
    missing=$((missing + 1))
    missing_list="$missing_list $ORG/$name"
    continue
  fi
  if [ -z "$prefix" ] || [ "$prefix" = "null" ]; then
    prefix="repo:$ORG/$name"
    note="   (GitHub reported no prefix: the classic form)"
  else
    note=""
  fi
  if ! [[ "$prefix" =~ $PREFIX_RE ]]; then
    echo "  $key: GitHub answered '$prefix', which is not a subject prefix (repo:<org>[@id]/<repo>[@id])." >&2
    bad=$((bad + 1))
    continue
  fi
  printf '  %-10s %s%s\n' "$key" "$prefix" "$note"
  [ -z "$json" ] || json="$json, "
  json="$json\"$key\": \"$prefix\""
done

if [ "$missing" -gt 0 ]; then
  echo >&2
  echo "oidc_subjects: $missing repositor$([ "$missing" -eq 1 ] && echo y || echo ies) could not be read. Create the four EMPTY public repositories first, then run this again:" >&2
  for full in $missing_list; do
    echo "  gh repo create $full --public" >&2
  done
  echo "(or the repository exists and gh is signed in to the wrong account: check 'gh auth status')" >&2
  exit 1
fi
[ "$bad" -eq 0 ] || die "nothing written." 1

target="$OUT_DIR/oidc_subjects.auto.tfvars.json"
tmp="$target.tmp.$$"
printf '{"sub_prefixes": {%s}}\n' "$json" > "$tmp"
mv "$tmp" "$target"
echo
echo "Wrote $target"
echo "terraform plan / apply in that folder now trusts exactly these prefixes (it loads the file by itself)."

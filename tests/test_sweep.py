"""scripts/sweep.sh -- with a fake `aws` that answers from a dict: no AWS, nothing is created or deleted.

The fake mimics what the real CLI prints with --output json for the account-wide list calls (including resources that are
NOT ours, which the sweep must ignore), records every call, and can be told to fail one of them."""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from conftest import FAKE_ACCOUNT, ROOT, run

SCRIPT = ROOT / "scripts" / "sweep.sh"

FAKE_AWS = '''#!/usr/bin/env python3
"""Records every call as one JSON line in $FAKE_LOG, then answers from the JSON file $FAKE_AWS_STATE.
Key = "<service> <operation>" (ecs list-services: "ecs list-services:<cluster>"; sagemaker list-*-jobs: "...:<status>";
sagemaker list-user-profiles: "...:<domain id>").
$FAKE_AWS_FAIL = a key whose call fails (exit 255, an error on stderr)."""
import json, os, sys
args = sys.argv[1:]
service, operation = args[0], args[1]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps({"tool": "aws", "args": args}) + "\\n")
key = f"{service} {operation}"
if service == "ecs" and operation == "list-services":
    key += ":" + args[args.index("--cluster") + 1]
if service == "sagemaker" and operation in ("list-training-jobs", "list-processing-jobs", "list-hyper-parameter-tuning-jobs"):
    key += ":" + args[args.index("--status-equals") + 1]
if service == "sagemaker" and operation == "list-user-profiles":
    key += ":" + args[args.index("--domain-id-equals") + 1]
if os.environ.get("FAKE_AWS_FAIL") in (key, f"{service} {operation}"):
    print("An error occurred (AccessDeniedException) when calling the " + operation + " operation", file=sys.stderr)
    sys.exit(255)
if key == "sts get-caller-identity":
    print("arn:aws:iam::" + os.environ["FAKE_ACCOUNT"] + ":user/class-admin")
    sys.exit(0)
state = json.load(open(os.environ["FAKE_AWS_STATE"]))
print(json.dumps(state.get(key, {})))
'''

ACCOUNT = FAKE_ACCOUNT
REGION = "ap-southeast-2"

# Things that are NOT ours: the sweep must neither list nor count them.
FOREIGN = {
    "ecr describe-repositories": {"repositories": [{"repositoryName": "frauddemo-app"}]},
    "s3api list-buckets": {"Buckets": [{"Name": "frauddemo-tfstate"}, {"Name": "my-photos"}]},
    "lambda list-functions": {"Functions": [{"FunctionName": "frauddemo-fn"}]},
    "ecs list-clusters": {"clusterArns": []},
    "elbv2 describe-load-balancers": {"LoadBalancers": [{"LoadBalancerName": "shop-alb"}]},
    "elbv2 describe-target-groups": {"TargetGroups": [{"TargetGroupName": "shop-tg"}]},
    "iam list-roles": {"Roles": [{"RoleName": "AWSServiceRoleForECS"}, {"RoleName": "frauddemo-role"}, {"RoleName": "not-finrisk-role"}]},
    "iam list-policies": {"Policies": [{"PolicyName": "frauddemo-policy"}]},
    "iam list-open-id-connect-providers": {"OpenIDConnectProviderList": [{"Arn": f"arn:aws:iam::{ACCOUNT}:oidc-provider/accounts.google.com"}]},
    "ssm get-parameters-by-path": {"Parameters": [{"Name": "/frauddemo/x", "Value": "v"}]},
    "logs describe-log-groups": {"logGroups": []},
    "sagemaker list-training-jobs:InProgress": {"TrainingJobSummaries": []},
    "sagemaker list-training-jobs:Stopping": {"TrainingJobSummaries": []},
    "sagemaker list-model-package-groups": {"ModelPackageGroupSummaryList": []},
    # week 13b rows: the real CLI filters by name on the server, but the sweep must filter again (and these names are not ours)
    "sagemaker list-endpoints": {"Endpoints": [{"EndpointName": "shop-recs"}]},
    "sagemaker list-endpoint-configs": {"EndpointConfigs": [{"EndpointConfigName": "shop-recs-cfg"}]},
    "sagemaker list-models": {"Models": [{"ModelName": "shop-recs-model"}]},
    "sagemaker list-pipelines": {"PipelineSummaries": [{"PipelineName": "shop-etl"}]},
    "sagemaker list-feature-groups": {"FeatureGroupSummaries": [{"FeatureGroupName": "shop-features"}]},
    "sagemaker list-model-cards": {"ModelCardSummaries": [{"ModelCardName": "shop-card"}]},
    # A deleted MLflow App keeps being listed for a while with Status "Deleted" (21 Oct 2026): a tombstone, not a leftover.
    "sagemaker list-mlflow-apps": {"Summaries": [{"Name": "shop-mlflow"}, {"Name": "finrisk-mlflow", "Status": "Deleted"}]},
    "sagemaker list-domains": {"Domains": [{"DomainName": "shop-studio", "DomainId": "d-shop00000001"}]},
    "sagemaker list-user-profiles:d-shop00000001": {"UserProfiles": [{"UserProfileName": "alice", "DomainId": "d-shop00000001"}]},
    "scheduler list-schedule-groups": {"ScheduleGroups": [{"Name": "default"}]},
    "scheduler list-schedules": {"Schedules": [{"Name": "shop-nightly", "GroupName": "default"}]},
    "events list-rules": {"Rules": [{"Name": "shop-rule"}]},
    "cloudwatch describe-alarms": {"MetricAlarms": [{"AlarmName": "shop-cpu"}], "CompositeAlarms": []},
    "glue get-databases": {"DatabaseList": [{"Name": "shop_ml"}, {"Name": "finrisk_ml_old_but_not_ours_x"}]},
    "athena list-work-groups": {"WorkGroups": [{"Name": "primary"}, {"Name": "shop"}]},
}

LEFTOVERS = {
    "ecr describe-repositories": {"repositories": [{"repositoryName": "finrisk-app"}, {"repositoryName": "finrisk-train"}, {"repositoryName": "frauddemo-app"}]},
    "s3api list-buckets": {"Buckets": [{"Name": f"finrisk-ml-{ACCOUNT}-{REGION}-an"}, {"Name": "frauddemo-tfstate"}]},
    "lambda list-functions": {"Functions": [{"FunctionName": "finrisk-dev"}]},
    "ecs list-clusters": {"clusterArns": [f"arn:aws:ecs:{REGION}:{ACCOUNT}:cluster/default", f"arn:aws:ecs:{REGION}:{ACCOUNT}:cluster/finrisk-old"]},
    "ecs list-services:default": {"serviceArns": [f"arn:aws:ecs:{REGION}:{ACCOUNT}:service/default/finrisk-prod"]},
    "ecs list-services:finrisk-old": {"serviceArns": []},
    "elbv2 describe-load-balancers": {"LoadBalancers": [{"LoadBalancerName": "ecs-express-gateway-alb-1a2b"}, {"LoadBalancerName": "shop-alb"}]},
    "elbv2 describe-target-groups": {"TargetGroups": [{"TargetGroupName": "ecs-gateway-tg-9"}]},
    "iam list-roles": {"Roles": [{"RoleName": "finrisk-app-build"}, {"RoleName": "finrisk-dev-runtime"}, {"RoleName": "AWSServiceRoleForECS"}]},
    "iam list-policies": {"Policies": [{"PolicyName": "finrisk-app-build"}]},
    "iam list-open-id-connect-providers": {"OpenIDConnectProviderList": [{"Arn": f"arn:aws:iam::{ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"}]},
    "ssm get-parameters-by-path": {"Parameters": [{"Name": "/finrisk/dev/model", "Value": '{"version": 1}'}, {"Name": "/finrisk/shared/ml_bucket", "Value": "x"}]},
    # one call answers both prefixes: the sweep must keep only the right one in each row
    "logs describe-log-groups": {"logGroups": [{"logGroupName": "/app/finrisk-dev"}, {"logGroupName": "/aws/lambda/finrisk-dev"}, {"logGroupName": "/aws/sagemaker/TrainingJobs"}]},
    "sagemaker list-training-jobs:InProgress": {"TrainingJobSummaries": [{"TrainingJobName": "finrisk-train-20261017-0100"}]},
    "sagemaker list-training-jobs:Stopping": {"TrainingJobSummaries": [{"TrainingJobName": "finrisk-train-20261017-0200"}]},
    "sagemaker list-model-package-groups": {"ModelPackageGroupSummaryList": [{"ModelPackageGroupName": "finrisk-fraud-model"}]},
}

# What week 13b leaves behind if nobody tears down: every new kind, plus a foreign neighbour of each that must not be counted.
MODEL_BLOCK_LEFTOVERS = {
    "sagemaker list-processing-jobs:InProgress": {"ProcessingJobSummaries": [{"ProcessingJobName": "finrisk-backfill-20261020-0100"}]},
    "sagemaker list-hyper-parameter-tuning-jobs:Stopping": {"HyperParameterTuningJobSummaries": [{"HyperParameterTuningJobName": "finrisk-tune-1"}]},
    "sagemaker list-endpoints": {"Endpoints": [{"EndpointName": "finrisk-prod-fraud"}, {"EndpointName": "finrisk-dev-fraud"}, {"EndpointName": "shop-recs"}]},
    "sagemaker list-endpoint-configs": {"EndpointConfigs": [{"EndpointConfigName": "finrisk-prod-fraud-v1-20261021031500"}]},
    "sagemaker list-models": {"Models": [{"ModelName": "finrisk-prod-fraud-v1-20261021031500"}, {"ModelName": "shop-recs-model"}]},
    "sagemaker list-pipelines": {"PipelineSummaries": [{"PipelineName": "finrisk-train"}, {"PipelineName": "finrisk-monitor"}]},
    "sagemaker list-feature-groups": {"FeatureGroupSummaries": [{"FeatureGroupName": "finrisk-transactions"}]},
    "sagemaker list-model-cards": {"ModelCardSummaries": [{"ModelCardName": "finrisk-fraud-card"}]},
    "sagemaker list-mlflow-apps": {"Summaries": [{"Name": "finrisk-mlflow"}, {"Name": "shop-mlflow"}]},
    "sagemaker list-domains": {"Domains": [{"DomainName": "finrisk-studio", "DomainId": "d-abc123456789"}, {"DomainName": "shop-studio", "DomainId": "d-shop00000001"}]},
    "sagemaker list-user-profiles:d-abc123456789": {"UserProfiles": [{"UserProfileName": "instructor", "DomainId": "d-abc123456789"}]},
    "scheduler list-schedule-groups": {"ScheduleGroups": [{"Name": "finrisk"}, {"Name": "default"}]},
    "scheduler list-schedules": {"Schedules": [{"Name": "finrisk-weekly-retrain", "GroupName": "finrisk"}, {"Name": "finrisk-hourly-monitor", "GroupName": "finrisk"}]},
    "events list-rules": {"Rules": [{"Name": "finrisk-retrain-on-drift"}]},
    "cloudwatch describe-alarms": {"MetricAlarms": [{"AlarmName": "finrisk-prod-model-drift"}, {"AlarmName": "finrisk-prod-endpoint-5xx"}, {"AlarmName": "shop-cpu"}], "CompositeAlarms": []},
    "glue get-databases": {"DatabaseList": [{"Name": "finrisk_ml"}, {"Name": "shop_ml"}]},
    "athena list-work-groups": {"WorkGroups": [{"Name": "primary"}, {"Name": "finrisk"}]},
}


@pytest.fixture
def sweep_env(tmp_path: Path):
    """(env, set_state): a PATH with the fake aws first, and a way to choose what the fake account contains."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    aws = fake_bin / "aws"
    aws.write_text(FAKE_AWS, encoding="utf-8")
    aws.chmod(aws.stat().st_mode | stat.S_IXUSR)
    state = tmp_path / "state.json"
    env = dict(os.environ)
    env.update(PATH=f"{fake_bin}{os.pathsep}{env['PATH']}", FAKE_LOG=str(tmp_path / "calls.jsonl"), FAKE_AWS_STATE=str(state),
               FAKE_ACCOUNT=ACCOUNT, AWS_REGION=REGION)
    for name in ("SWEEP_KEEP_OIDC", "FAKE_AWS_FAIL", "AWS_DEFAULT_REGION"):
        env.pop(name, None)

    def set_state(extra: dict) -> None:
        state.write_text(json.dumps({**FOREIGN, **extra}), encoding="utf-8")

    set_state({})
    return env, set_state


def calls(env: dict) -> list[list[str]]:
    path = Path(env["FAKE_LOG"])
    if not path.exists():
        return []
    return [json.loads(line)["args"] for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def sweep(env: dict, shell: str = "bash") -> subprocess.CompletedProcess:
    return run([shell, str(SCRIPT)], env)


def row(out: str, label: str) -> str:
    return next(line for line in out.splitlines() if line.startswith(label))


SHELLS = ["bash"] + (["/bin/bash"] if Path("/bin/bash").exists() and shutil.which("bash") != "/bin/bash" else [])


def test_script_is_valid_bash():
    for shell in SHELLS:
        assert subprocess.run([shell, "-n", str(SCRIPT)], capture_output=True).returncode == 0


def test_no_bash_4_only_features():
    text = "\n".join(line for line in SCRIPT.read_text(encoding="utf-8").splitlines() if not line.lstrip().startswith("#"))
    for banned in ("mapfile", "readarray", "declare -A", "local -A", ",,}", "^^}"):
        assert banned not in text, banned


@pytest.mark.parametrize("shell", SHELLS)
def test_a_clean_account_prints_total_0_and_exits_0(sweep_env, shell):
    env, _ = sweep_env
    done = sweep(env, shell)
    assert done.returncode == 0, done.stdout + done.stderr
    assert done.stdout.rstrip().splitlines()[-1] == "TOTAL 0 left"
    assert "frauddemo" not in done.stdout and "shop-" not in done.stdout       # other people's things are ignored
    assert "NOT proven" not in done.stdout


@pytest.mark.parametrize("shell", SHELLS)
def test_leftovers_are_listed_counted_and_masked(sweep_env, shell):
    env, set_state = sweep_env
    set_state(LEFTOVERS)
    done = sweep(env, shell)
    out = done.stdout
    assert done.returncode == 1, out + done.stderr
    assert row(out, "ECR repositories").split()[-3:] == ["2", "finrisk-app", "finrisk-train"]
    assert "finrisk-ml-<account-id>-ap-southeast-2-an" in row(out, "S3 buckets")
    assert "finrisk-dev" in row(out, "Lambda functions")
    assert "default/finrisk-prod" in row(out, "ECS services")
    assert "finrisk-old" in row(out, "ECS clusters") and "default" not in row(out, "ECS clusters")
    assert "ecs-express-gateway-alb-1a2b" in row(out, "Load balancers") and "shop-alb" not in out
    assert "ecs-gateway-tg-9" in row(out, "Target groups")
    assert "finrisk-app-build finrisk-dev-runtime" in row(out, "IAM roles") and "AWSServiceRole" not in out
    assert "finrisk-app-build" in row(out, "IAM policies")
    assert "oidc-provider/token.actions.githubusercontent.com" in row(out, "GitHub OIDC provider")
    assert row(out, "SSM parameters").split()[-3:] == ["2", "/finrisk/dev/model", "/finrisk/shared/ml_bucket"]
    assert "/app/finrisk-dev" in row(out, "Log groups /app/finrisk-*") and "/aws/lambda" not in row(out, "Log groups /app/finrisk-*")
    assert "/aws/lambda/finrisk-dev" in row(out, "Log groups /aws/lambda/finrisk-*") and "/app/" not in row(out, "Log groups /aws/lambda/finrisk-*")
    assert "TrainingJobs" not in out                                            # SageMaker's own log group is not ours
    assert "finrisk-train-20261017-0100 finrisk-train-20261017-0200" in row(out, "SageMaker training jobs")   # InProgress, then Stopping
    assert "finrisk-fraud-model" in row(out, "SageMaker model package groups")
    # 2 ECR + 1 S3 + 1 Lambda + 1 ECS service + 1 cluster + 1 LB + 1 TG + 2 roles + 1 policy + 1 OIDC + 2 SSM
    # + 1 + 1 log groups + 2 jobs + 1 model group = 19
    assert out.rstrip().splitlines()[-1] == "TOTAL 19 left"
    assert not re.search(r"\d{12}", out + done.stderr)                         # no account id, anywhere
    assert "<account-id>" in out


def test_the_oidc_provider_can_be_kept_out_of_the_count(sweep_env):
    env, set_state = sweep_env
    set_state({"iam list-open-id-connect-providers": LEFTOVERS["iam list-open-id-connect-providers"]})
    assert sweep(env).stdout.rstrip().splitlines()[-1] == "TOTAL 1 left"
    env["SWEEP_KEEP_OIDC"] = "1"
    done = sweep(env)
    assert done.returncode == 0
    assert "(not counted)" in row(done.stdout, "GitHub OIDC provider")
    assert done.stdout.rstrip().splitlines()[-1] == "TOTAL 0 left"


def test_it_only_reads(sweep_env):
    env, set_state = sweep_env
    set_state(LEFTOVERS)
    assert sweep(env).returncode == 1
    made = calls(env)
    assert made
    for args in made:
        assert args[1].split("-")[0] in {"list", "describe", "get"}, args       # list-*, describe-*, get-*
        assert "--region" in args or args[0] in {"iam"}, args                    # regional calls name the Region
    assert all(a[0] != "sts" or a[1] == "get-caller-identity" for a in made)
    assert ["ecs", "list-services", "--cluster", "default", "--region", REGION, "--output", "json"] in made
    assert not any(a[1].startswith(("create", "put", "delete", "update", "run", "start", "stop", "terminate")) for a in made)


def test_the_region_comes_from_aws_region(sweep_env):
    env, _ = sweep_env
    env["AWS_REGION"] = "us-east-1"
    sweep(env)
    regional = [a for a in calls(env) if "--region" in a]
    assert regional and all(a[a.index("--region") + 1] == "us-east-1" for a in regional)
    assert "us-east-1" in sweep(env).stdout.splitlines()[0]


def test_a_failed_check_is_never_reported_as_clean(sweep_env):
    env, _ = sweep_env
    env["FAKE_AWS_FAIL"] = "iam list-roles"
    done = sweep(env)
    assert done.returncode == 1
    assert "could not check" in row(done.stdout, "IAM roles")
    assert "AccessDeniedException" in row(done.stdout, "IAM roles")
    assert "NOT proven clean" in done.stdout.rstrip().splitlines()[-1]
    assert row(done.stdout, "IAM policies").endswith("0")                       # the other rows still ran


def test_a_failing_ecs_service_listing_is_reported(sweep_env):
    env, set_state = sweep_env
    set_state(LEFTOVERS)
    env["FAKE_AWS_FAIL"] = "ecs list-services:default"
    done = sweep(env)
    assert done.returncode == 1
    assert "could not check" in row(done.stdout, "ECS services")
    assert "NOT proven clean" in done.stdout


def test_not_signed_in_stops_before_anything_else(sweep_env):
    env, _ = sweep_env
    env["FAKE_AWS_FAIL"] = "sts get-caller-identity"
    done = sweep(env)
    assert done.returncode == 2
    assert "aws login" in done.stderr
    assert [a[:2] for a in calls(env)] == [["sts", "get-caller-identity"]]
    assert "TOTAL" not in done.stdout


@pytest.mark.parametrize("shell", SHELLS)
def test_the_model_block_leftovers_are_listed_counted_and_masked(sweep_env, shell):
    """Week 13b: endpoints, configs, models, pipelines, feature groups, model cards, MLflow apps, Studio (domain + profile),
    processing and tuning jobs, schedules, rules, alarms, the Glue database and the Athena workgroup."""
    env, set_state = sweep_env
    set_state(MODEL_BLOCK_LEFTOVERS)
    done = sweep(env, shell)
    out = done.stdout
    assert done.returncode == 1, out + done.stderr
    assert row(out, "SageMaker processing jobs running").split()[-2:] == ["1", "finrisk-backfill-20261020-0100"] or "finrisk-backfill-20261020-0100" in row(out, "SageMaker processing jobs running")
    assert "finrisk-tune-1" in row(out, "SageMaker tuning jobs running")
    assert "finrisk-prod-fraud finrisk-dev-fraud" in row(out, "SageMaker endpoints") and "shop-recs" not in out
    assert "finrisk-prod-fraud-v1-20261021031500" in row(out, "SageMaker endpoint configs")
    assert row(out, "SageMaker models").endswith("finrisk-prod-fraud-v1-20261021031500") and "shop-recs-model" not in out
    assert "finrisk-train finrisk-monitor" in row(out, "SageMaker pipelines")
    assert "finrisk-transactions" in row(out, "SageMaker feature groups")
    assert "finrisk-fraud-card" in row(out, "SageMaker model cards")
    assert row(out, "SageMaker MLflow apps").endswith("finrisk-mlflow") and "shop-mlflow" not in out
    assert row(out, "SageMaker Studio domains").endswith("finrisk-studio") and "shop-studio" not in out
    assert "d-abc123456789/instructor" in row(out, "SageMaker Studio user profiles") and "alice" not in out
    assert "finrisk" in row(out, "EventBridge schedule groups") and "default" not in row(out, "EventBridge schedule groups")
    assert "finrisk-weekly-retrain finrisk-hourly-monitor" in row(out, "EventBridge schedules")
    assert "finrisk-retrain-on-drift" in row(out, "EventBridge rules")
    assert "finrisk-prod-model-drift finrisk-prod-endpoint-5xx" in row(out, "CloudWatch alarms") and "shop-cpu" not in out
    assert row(out, "Glue database finrisk_ml").endswith("finrisk_ml") and "shop_ml" not in out
    assert row(out, "Athena workgroup finrisk").endswith("finrisk") and "primary" not in out
    # 1 processing + 1 tuning + 2 endpoints + 1 config + 1 model + 2 pipelines + 1 feature group + 1 card + 1 MLflow app
    # + 1 domain + 1 profile + 1 group + 2 schedules + 1 rule + 2 alarms + 1 database + 1 workgroup = 21
    assert out.rstrip().splitlines()[-1] == "TOTAL 21 left"
    assert not re.search(r"(?<!\d)\d{12}(?!\d)", out + done.stderr)      # no account id (the 14-digit timestamp in a config name is not one)
    assert "finrisk-prod-fraud-v1-20261021031500" in out                   # ... and it stays readable


def test_every_model_block_row_exists_in_a_clean_account_and_the_sweep_can_still_reach_total_0(sweep_env):
    env, _ = sweep_env
    done = sweep(env)
    assert done.returncode == 0, done.stdout + done.stderr
    for label in ("SageMaker training jobs running", "SageMaker processing jobs running", "SageMaker tuning jobs running",
                  "SageMaker endpoints", "SageMaker endpoint configs", "SageMaker models", "SageMaker pipelines",
                  "SageMaker feature groups", "SageMaker model cards", "SageMaker MLflow apps", "SageMaker Studio domains",
                  "SageMaker Studio user profiles", "EventBridge schedule groups", "EventBridge schedules", "EventBridge rules",
                  "CloudWatch alarms", "Glue database finrisk_ml", "Athena workgroup finrisk"):
        assert row(done.stdout, label).endswith("0"), label
    assert done.stdout.rstrip().splitlines()[-1] == "TOTAL 0 left"


def test_the_model_block_calls_only_read_and_name_the_region(sweep_env):
    env, set_state = sweep_env
    set_state(MODEL_BLOCK_LEFTOVERS)
    sweep(env)
    made = calls(env)
    for service, operation in (("sagemaker", "list-endpoints"), ("sagemaker", "list-pipelines"), ("sagemaker", "list-mlflow-apps"),
                               ("sagemaker", "list-model-cards"), ("sagemaker", "list-feature-groups"), ("sagemaker", "list-domains"),
                               ("scheduler", "list-schedules"), ("events", "list-rules"), ("cloudwatch", "describe-alarms"),
                               ("glue", "get-databases"), ("athena", "list-work-groups")):
        hits = [a for a in made if a[:2] == [service, operation]]
        assert hits, (service, operation)
        assert all("--region" in a for a in hits)
    assert any(a[:2] == ["sagemaker", "list-user-profiles"] and "d-abc123456789" in a for a in made)
    assert not any(a[1].startswith(("create", "put", "delete", "update", "run", "start", "stop", "terminate")) for a in made)


def test_a_failing_model_block_check_is_never_reported_as_clean(sweep_env):
    env, _ = sweep_env
    env["FAKE_AWS_FAIL"] = "sagemaker list-endpoints"
    done = sweep(env)
    assert done.returncode == 1
    assert "could not check" in row(done.stdout, "SageMaker endpoints")
    assert "NOT proven clean" in done.stdout.rstrip().splitlines()[-1]
    assert row(done.stdout, "SageMaker pipelines").endswith("0")                   # the other rows still ran

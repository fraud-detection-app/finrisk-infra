# Offline test of the ECS Express Mode branch (prod). Needs workspace "prod": bash scripts/tf_checks.sh envs

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-2"
    }
  }
}

override_data {
  target = data.aws_ssm_parameter.ml_bucket
  values = {
    insecure_value = "finrisk-ml-123456789012-ap-southeast-2-an"
  }
}

override_data {
  target = data.aws_ssm_parameter.kb_bucket
  values = {
    insecure_value = "finrisk-kb-123456789012-ap-southeast-2-an"
  }
}

variables {
  env                = "prod"
  compute            = "ecs"
  log_retention_days = 90
  bucket_versioning  = true
}

run "prod_creates_the_two_express_roles" {
  command = plan

  assert {
    condition     = length(aws_iam_role.ecs_execution) == 1 && length(aws_iam_role.ecs_infrastructure) == 1 && length(aws_iam_role_policy_attachment.ecs_execution) == 1 && length(aws_iam_role_policy_attachment.ecs_infrastructure) == 1
    error_message = "prod (ECS) needs the execution and infrastructure roles with their managed policies."
  }

  assert {
    condition     = aws_iam_role.ecs_execution[0].name == "finrisk-prod-ecs-execution" && aws_iam_role.ecs_infrastructure[0].name == "finrisk-prod-ecs-infrastructure" && aws_iam_role.runtime.name == "finrisk-prod-runtime"
    error_message = "Role names: finrisk-<env>-ecs-execution / -ecs-infrastructure / -runtime."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ecs_execution[0].assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com" && jsondecode(aws_iam_role.ecs_infrastructure[0].assume_role_policy).Statement[0].Principal.Service == "ecs.amazonaws.com"
    error_message = "Execution role: ecs-tasks. Infrastructure role: ecs."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ecs_execution[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" && aws_iam_role_policy_attachment.ecs_infrastructure[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
    error_message = "Only the two AWS-managed policies ECS Express needs."
  }
}

run "prod_bucket_logs_and_parameters" {
  command = plan

  assert {
    condition     = aws_s3_bucket.env.bucket == "finrisk-prod-123456789012-ap-southeast-2-an" && aws_s3_bucket.env.force_destroy != true && aws_s3_bucket_versioning.env.versioning_configuration[0].status == "Enabled"
    error_message = "prod: versioned bucket that destroy never empties."
  }

  assert {
    condition     = aws_cloudwatch_log_group.app.name == "/app/finrisk-prod" && aws_cloudwatch_log_group.app.retention_in_days == 90
    error_message = "prod logs: /app/finrisk-prod, 90 days."
  }

  assert {
    condition = toset([for p in aws_ssm_parameter.env : p.name]) == toset([
      "/finrisk/prod/runtime_role_arn", "/finrisk/prod/log_group", "/finrisk/prod/bucket",
      "/finrisk/prod/ecs_execution_role_arn", "/finrisk/prod/ecs_infrastructure_role_arn", "/finrisk/prod/endpoint_role_arn",
    ])
    error_message = "An ECS environment also publishes ecs_execution_role_arn and ecs_infrastructure_role_arn (and every environment endpoint_role_arn)."
  }

  assert {
    condition     = aws_ssm_parameter.model_pointer.name == "/finrisk/prod/model" && aws_ssm_parameter.index_pointer.name == "/finrisk/prod/index"
    error_message = "The pointers are /finrisk/<env>/model and /index."
  }
}

run "prod_runtime_role_reads_only_its_own_and_shared" {
  command = apply

  assert {
    condition = (
      strcontains(aws_iam_role_policy.runtime.policy, "parameter/finrisk/prod/*") && strcontains(aws_iam_role_policy.runtime.policy, "parameter/finrisk/shared/*") &&
      !strcontains(aws_iam_role_policy.runtime.policy, "finrisk/dev") && !strcontains(aws_iam_role_policy.runtime.policy, "finrisk/sit")
    )
    error_message = "The prod runtime role reads /finrisk/prod/* and /finrisk/shared/* only."
  }
}

run "prod_pointers_ignore_a_promoted_value" {
  command = apply
}

run "prod_second_apply_keeps_the_pointer" {
  command = plan

  variables {
    pointer_seed = "{\"version\": 3}"
  }

  assert {
    condition     = nonsensitive(aws_ssm_parameter.model_pointer.value) == "{\"version\": null}"
    error_message = "ignore_changes = [value] keeps what the first apply wrote."
  }
}

# ------------------------------------------------------------------ week 13b: the prod endpoint and the three model alarms
run "prod_endpoint_role_writes_capture_prod_only" {
  command = apply

  assert {
    condition = (
      aws_iam_role.endpoint.name == "finrisk-prod-endpoint" &&
      [for s in jsondecode(aws_iam_role_policy.endpoint.policy).Statement : s.Resource if s.Sid == "WriteDataCapture"][0] == "arn:aws:s3:::finrisk-ml-123456789012-ap-southeast-2-an/capture/prod/*" &&
      !strcontains(aws_iam_role_policy.endpoint.policy, "pre-prod") && !strcontains(aws_iam_role_policy.endpoint.policy, "finrisk-dev") && !strcontains(aws_iam_role_policy.endpoint.policy, "finrisk-sit") &&
      strcontains(aws_iam_role_policy.endpoint.policy, "/aws/sagemaker/Endpoints/finrisk-prod-fraud")
    )
    error_message = "The prod endpoint writes capture/prod/* and its own log group, and knows no other environment."
  }

  # The blue/green guardrail reads the rollback alarms AS THE ENDPOINT ROLE; denied = every update rolls back (21 Oct 2026).
  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.endpoint.policy).Statement : s.Action if s.Sid == "ReadTheRollbackAlarms"][0] == ["cloudwatch:DescribeAlarms"] &&
      [for s in jsondecode(aws_iam_role_policy.endpoint.policy).Statement : s.Resource if s.Sid == "ReadTheRollbackAlarms"][0] == "*"
    )
    error_message = "The prod endpoint role must be able to read the rollback alarms (cloudwatch:DescribeAlarms, read-only)."
  }
}

run "prod_has_the_guardrails_and_the_three_model_alarms_exactly_as_designed" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.endpoint["5xx"].alarm_name == "finrisk-prod-endpoint-5xx" && aws_cloudwatch_metric_alarm.endpoint["latency"].alarm_name == "finrisk-prod-endpoint-latency" && jsonencode(aws_cloudwatch_metric_alarm.endpoint["5xx"].dimensions) == jsonencode({ EndpointName = "finrisk-prod-fraud", VariantName = "AllTraffic" })
    error_message = "Guardrails: finrisk-prod-endpoint-5xx and -latency on finrisk-prod-fraud / AllTraffic."
  }

  # drift: MAX([MaxFeaturePSI, ScorePSI]) >= 0.25
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.model_drift[0].alarm_name == "finrisk-prod-model-drift" &&
      aws_cloudwatch_metric_alarm.model_drift[0].comparison_operator == "GreaterThanOrEqualToThreshold" &&
      aws_cloudwatch_metric_alarm.model_drift[0].threshold == 0.25 &&
      aws_cloudwatch_metric_alarm.model_drift[0].evaluation_periods == 1 && aws_cloudwatch_metric_alarm.model_drift[0].datapoints_to_alarm == 1 &&
      aws_cloudwatch_metric_alarm.model_drift[0].treat_missing_data == "notBreaching" &&
      one([for q in aws_cloudwatch_metric_alarm.model_drift[0].metric_query : q if q.return_data == true]).expression == "MAX([max_feature_psi, score_psi])" &&
      toset([for q in aws_cloudwatch_metric_alarm.model_drift[0].metric_query : q.metric[0].metric_name if length(q.metric) > 0]) == toset(["MaxFeaturePSI", "ScorePSI"]) &&
      alltrue([for q in aws_cloudwatch_metric_alarm.model_drift[0].metric_query : q.metric[0].namespace == "FinRisk/Model" && jsonencode(q.metric[0].dimensions) == jsonencode({ Env = "prod" }) && q.metric[0].period == 300 if length(q.metric) > 0])
    )
    error_message = "finrisk-prod-model-drift: MAX([MaxFeaturePSI, ScorePSI]) >= 0.25, namespace FinRisk/Model, Env=prod, 300 s, 1 of 1, missing = notBreaching."
  }

  # prior shift: FraudRateRatio >= 5
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.model_prior_shift[0].alarm_name == "finrisk-prod-model-prior-shift" &&
      aws_cloudwatch_metric_alarm.model_prior_shift[0].namespace == "FinRisk/Model" &&
      aws_cloudwatch_metric_alarm.model_prior_shift[0].metric_name == "FraudRateRatio" &&
      jsonencode(aws_cloudwatch_metric_alarm.model_prior_shift[0].dimensions) == jsonencode({ Env = "prod" }) &&
      aws_cloudwatch_metric_alarm.model_prior_shift[0].comparison_operator == "GreaterThanOrEqualToThreshold" &&
      aws_cloudwatch_metric_alarm.model_prior_shift[0].threshold == 5 &&
      aws_cloudwatch_metric_alarm.model_prior_shift[0].period == 300 &&
      aws_cloudwatch_metric_alarm.model_prior_shift[0].evaluation_periods == 1 && aws_cloudwatch_metric_alarm.model_prior_shift[0].datapoints_to_alarm == 1 &&
      aws_cloudwatch_metric_alarm.model_prior_shift[0].treat_missing_data == "notBreaching"
    )
    error_message = "finrisk-prod-model-prior-shift: FraudRateRatio >= 5, Env=prod, 300 s, 1 of 1, missing = notBreaching."
  }

  # quality: IF(LabelledRows >= 500, LivePrAuc, 1) < 0.70
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.model_quality[0].alarm_name == "finrisk-prod-model-quality" &&
      aws_cloudwatch_metric_alarm.model_quality[0].comparison_operator == "LessThanThreshold" &&
      aws_cloudwatch_metric_alarm.model_quality[0].threshold == 0.7 &&
      aws_cloudwatch_metric_alarm.model_quality[0].evaluation_periods == 1 && aws_cloudwatch_metric_alarm.model_quality[0].datapoints_to_alarm == 1 &&
      aws_cloudwatch_metric_alarm.model_quality[0].treat_missing_data == "notBreaching" &&
      one([for q in aws_cloudwatch_metric_alarm.model_quality[0].metric_query : q if q.return_data == true]).expression == "IF(labelled_rows >= 500, live_pr_auc, 1)" &&
      toset([for q in aws_cloudwatch_metric_alarm.model_quality[0].metric_query : q.metric[0].metric_name if length(q.metric) > 0]) == toset(["LabelledRows", "LivePrAuc"]) &&
      alltrue([for q in aws_cloudwatch_metric_alarm.model_quality[0].metric_query : q.metric[0].namespace == "FinRisk/Model" && jsonencode(q.metric[0].dimensions) == jsonencode({ Env = "prod" }) && q.metric[0].period == 300 if length(q.metric) > 0])
    )
    error_message = "finrisk-prod-model-quality: IF(LabelledRows >= 500, LivePrAuc, 1) < 0.70, Env=prod, 300 s, 1 of 1, missing = notBreaching."
  }

  # The EventBridge rule in shared/ matches alarm names starting finrisk-prod-model-: all three names start with it.
  assert {
    condition     = alltrue([for n in [aws_cloudwatch_metric_alarm.model_drift[0].alarm_name, aws_cloudwatch_metric_alarm.model_prior_shift[0].alarm_name, aws_cloudwatch_metric_alarm.model_quality[0].alarm_name] : startswith(n, "finrisk-prod-model-")])
    error_message = "Every prod model alarm name starts finrisk-prod-model- (the retrain-on-drift rule matches that prefix)."
  }
}

run "the_alarm_thresholds_are_variables" {
  command = plan

  variables {
    drift_psi_threshold        = 0.4
    fraud_rate_ratio_threshold = 8
    live_pr_auc_floor          = 0.6
    min_labelled_rows          = 1000
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.model_drift[0].threshold == 0.4 &&
      aws_cloudwatch_metric_alarm.model_prior_shift[0].threshold == 8 &&
      aws_cloudwatch_metric_alarm.model_quality[0].threshold == 0.6 &&
      one([for q in aws_cloudwatch_metric_alarm.model_quality[0].metric_query : q if q.return_data == true]).expression == "IF(labelled_rows >= 1000, live_pr_auc, 1)"
    )
    error_message = "drift_psi_threshold, fraud_rate_ratio_threshold, live_pr_auc_floor and min_labelled_rows reach the alarms."
  }
}

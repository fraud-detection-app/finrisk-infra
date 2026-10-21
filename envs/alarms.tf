# CloudWatch alarms (week 13b). Two families, and neither takes any action by itself:
#
#   1. endpoint GUARDRAILS (pre-prod, prod): finrisk-<env>-endpoint-5xx and -latency. They watch the endpoint while a NEW model version
#      goes live. finrisk-ml's blue/green update names them as its auto-rollback alarms: if either goes to ALARM during the canary and
#      bake, SageMaker puts the old version back by itself.
#   2. MODEL alarms (prod only): finrisk-prod-model-drift, -prior-shift, -quality. They watch what the MODEL does to the world,
#      from the metrics our monitor job publishes (namespace FinRisk/Model, dimension Env=prod). When one goes to ALARM, the
#      EventBridge rule finrisk-retrain-on-drift (shared/) starts a retraining run. The gate and the human approval still decide
#      what reaches prod.
#
# Why our own monitor and not SageMaker Model Monitor? Model Monitor and Clarify are closed to new customers since 30 July 2026, so
# the monitor is a job of ours that writes plain CloudWatch metrics. An alarm needs nothing more.
#
# All model alarms: period 300 s, 1 of 1 datapoints, MISSING data is "not breaching". The monitor publishes only when it runs; no
# data means "nobody looked", not "something is wrong", and an alarm that fires on silence would retrain a model for no reason.

# ---------------------------------------------------------------- 1. the endpoint guardrails
locals {
  endpoint_alarms = local.realtime_endpoint ? {
    "5xx" = {
      description         = "The ${local.endpoint_name} endpoint returned at least one 5xx error in a minute. During a blue/green update this rolls the new version back."
      metric_name         = "Invocation5XXErrors"
      statistic           = "Sum"
      extended_statistic  = null
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      threshold           = 1
      comparison          = "GreaterThanOrEqualToThreshold"
    }
    "latency" = {
      description         = "The ${local.endpoint_name} endpoint's p90 model latency is over 2 seconds for two minutes in a row. During a blue/green update this rolls the new version back."
      metric_name         = "ModelLatency"
      statistic           = null
      extended_statistic  = "p90"
      evaluation_periods  = 2
      datapoints_to_alarm = 2
      threshold           = 2000000 # ModelLatency is reported in MICROseconds: 2,000,000 = 2 s
      comparison          = "GreaterThanThreshold"
    }
  } : {}
}

resource "aws_cloudwatch_metric_alarm" "endpoint" {
  for_each = local.endpoint_alarms

  alarm_name        = "${local.name}-endpoint-${each.key}"
  alarm_description = each.value.description

  namespace           = "AWS/SageMaker"
  metric_name         = each.value.metric_name
  dimensions          = { EndpointName = local.endpoint_name, VariantName = "AllTraffic" }
  statistic           = each.value.statistic
  extended_statistic  = each.value.extended_statistic
  period              = 60
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison

  # A quiet endpoint sends no datapoints: that is not a failure.
  treat_missing_data = "notBreaching"

  depends_on = [terraform_data.workspace_matches_env]
}

# ---------------------------------------------------------------- 2. the model alarms (prod only)
# Dimension Env only -- never the model version -- so the alarm keeps working when v2 replaces v1.
locals {
  model_namespace = "FinRisk/Model"
  model_dims      = { Env = "prod" }
}

# "The data moved": the LARGEST per-feature PSI, or the score's PSI, is in the "significant shift" band. Metric math, because
# the alarm looks at two metrics and takes the bigger. (The SHARE of drifting features is the wrong alarm: in the measured
# class run 1 of 11 features drifted, and it was the one that mattered.)
resource "aws_cloudwatch_metric_alarm" "model_drift" {
  count = local.is_prod ? 1 : 0

  alarm_name          = "${local.name}-model-drift"
  alarm_description   = "The data the prod model sees has moved: the largest feature PSI or the score PSI is >= ${var.drift_psi_threshold}."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.drift_psi_threshold
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "worst"
    expression  = "MAX([max_feature_psi, score_psi])"
    label       = "worst PSI (largest feature, score)"
    return_data = true
  }

  metric_query {
    id = "max_feature_psi"

    metric {
      namespace   = local.model_namespace
      metric_name = "MaxFeaturePSI"
      dimensions  = local.model_dims
      period      = 300
      stat        = "Maximum"
    }
  }

  metric_query {
    id = "score_psi"

    metric {
      namespace   = local.model_namespace
      metric_name = "ScorePSI"
      dimensions  = local.model_dims
      period      = 300
      stat        = "Maximum"
    }
  }

  depends_on = [terraform_data.workspace_matches_env]
}

# "The world changed how often fraud happens" (prior / label shift): fraud is at least N times as common as in the training data.
resource "aws_cloudwatch_metric_alarm" "model_prior_shift" {
  count = local.is_prod ? 1 : 0

  alarm_name          = "${local.name}-model-prior-shift"
  alarm_description   = "Fraud is >= ${var.fraud_rate_ratio_threshold}x as common in live traffic as in the data the prod model was trained on."
  namespace           = local.model_namespace
  metric_name         = "FraudRateRatio"
  dimensions          = local.model_dims
  statistic           = "Maximum"
  period              = 300
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.fraud_rate_ratio_threshold
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  treat_missing_data  = "notBreaching"

  depends_on = [terraform_data.workspace_matches_env]
}

# "The model got worse where we can check": live PR-AUC below the floor -- but ONLY once enough live rows have a label. With fewer
# labelled rows the expression is 1 (a perfect score), which can never breach. (A guard, not the main trigger: when fraud becomes
# more common, PR-AUC usually RISES.)
resource "aws_cloudwatch_metric_alarm" "model_quality" {
  count = local.is_prod ? 1 : 0

  alarm_name          = "${local.name}-model-quality"
  alarm_description   = "The prod model's live PR-AUC is below ${var.live_pr_auc_floor} on at least ${var.min_labelled_rows} labelled rows."
  comparison_operator = "LessThanThreshold"
  threshold           = var.live_pr_auc_floor
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "judged_pr_auc"
    expression  = "IF(labelled_rows >= ${var.min_labelled_rows}, live_pr_auc, 1)"
    label       = "live PR-AUC (judged only with enough labels)"
    return_data = true
  }

  metric_query {
    id = "labelled_rows"

    metric {
      namespace   = local.model_namespace
      metric_name = "LabelledRows"
      dimensions  = local.model_dims
      period      = 300
      stat        = "Maximum"
    }
  }

  metric_query {
    id = "live_pr_auc"

    metric {
      namespace   = local.model_namespace
      metric_name = "LivePrAuc"
      dimensions  = local.model_dims
      period      = 300
      stat        = "Minimum"
    }
  }

  depends_on = [terraform_data.workspace_matches_env]
}

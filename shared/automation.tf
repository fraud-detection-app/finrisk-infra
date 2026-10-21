# Who starts the pipelines when no person does (week 13b). Three triggers, all in AWS, none in GitHub:
#
#   weekly      EventBridge Scheduler  finrisk-weekly-retrain   Monday 02:00 Sydney -> finrisk-train   (TriggerReason=schedule)
#   hourly      EventBridge Scheduler  finrisk-hourly-monitor   every hour          -> finrisk-monitor (Env=prod)   OFF by default
#   on drift    EventBridge rule       finrisk-retrain-on-drift  a prod model alarm goes to ALARM -> finrisk-train (TriggerReason=drift)
#
# The pipelines themselves are made by finrisk-ml (plain JSON, upserted by train.yml); these triggers only name them. A trigger
# that fires before its pipeline exists simply fails to start: nothing is created, nothing bills.
#
# Why Scheduler for the clock and a rule for the alarm? EventBridge Scheduler is the service for "at this time" (time zones, one-off
# or recurring); a rule is the service for "when this happened" (it matches events). Both can start a pipeline directly: AWS gives
# each a ready-made SageMaker Pipeline target, so no Lambda sits in between.
#
# The gate and the human approval still stand between whatever these start and prod: a pipeline run only REGISTERS a version
# as PendingManualApproval (or refuses it). Nothing here deploys anything.

# ---------------------------------------------------------------- the roles the triggers wear
# Each may start the pipelines it needs and nothing else. Each is trusted by ONE service, for this account only.
resource "aws_iam_role" "scheduler" {
  name = "${var.project}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.acct } }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.project}-scheduler"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "StartTheTwoPipelines"
      Effect   = "Allow"
      Action   = ["sagemaker:StartPipelineExecution"]
      Resource = [local.train_pipeline_arn, local.monitor_pipeline_arn]
    }]
  })
}

resource "aws_iam_role" "events" {
  name = "${var.project}-events"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.acct } }
    }]
  })
}

resource "aws_iam_role_policy" "events" {
  name = "${var.project}-events"
  role = aws_iam_role.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # Only the TRAINING pipeline: an alarm can start a retraining run, never a monitor run.
      Sid      = "StartTheTrainingPipeline"
      Effect   = "Allow"
      Action   = ["sagemaker:StartPipelineExecution"]
      Resource = local.train_pipeline_arn
    }]
  })
}

# ---------------------------------------------------------------- the clock: EventBridge Scheduler
resource "aws_scheduler_schedule_group" "this" {
  name = local.schedule_group
}

resource "aws_scheduler_schedule" "weekly_retrain" {
  name        = "${var.project}-weekly-retrain"
  group_name  = aws_scheduler_schedule_group.this.name
  description = "Every Monday 02:00 Sydney: start the training pipeline with every label that has arrived by then."
  state       = var.weekly_retrain_enabled ? "ENABLED" : "DISABLED"

  # cron(minutes hours day-of-month month day-of-week year). Daylight saving is handled by the time zone.
  schedule_expression          = "cron(0 2 ? * MON *)"
  schedule_expression_timezone = "Australia/Sydney"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = local.train_pipeline_arn
    role_arn = aws_iam_role.scheduler.arn

    sagemaker_pipeline_parameters {
      pipeline_parameter {
        name  = "TriggerReason"
        value = "schedule"
      }
    }

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }

  depends_on = [aws_iam_role_policy.scheduler]
}

# OFF unless var.monitor_schedule_enabled: in class the monitor is started by hand so the students see it run.
resource "aws_scheduler_schedule" "hourly_monitor" {
  name        = "${var.project}-hourly-monitor"
  group_name  = aws_scheduler_schedule_group.this.name
  description = "Every hour: start the monitor pipeline for prod (drift + live quality -> CloudWatch -> alarms). Disabled unless monitor_schedule_enabled."
  state       = var.monitor_schedule_enabled ? "ENABLED" : "DISABLED"

  schedule_expression = "rate(1 hour)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = local.monitor_pipeline_arn
    role_arn = aws_iam_role.scheduler.arn

    sagemaker_pipeline_parameters {
      pipeline_parameter {
        name  = "Env"
        value = "prod"
      }
    }

    retry_policy {
      maximum_retry_attempts       = 0
      maximum_event_age_in_seconds = 900
    }
  }

  depends_on = [aws_iam_role_policy.scheduler]
}

# ---------------------------------------------------------------- the alarm: an EventBridge rule
# CloudWatch tells EventBridge every time an alarm changes state. This rule keeps only: "a finrisk-prod-model-* alarm just
# became ALARM". (The alarms are made by envs/, prod only: finrisk-prod-model-drift, -prior-shift, -quality.) It fires once
# per transition, so two alarms in one monitor run start at most two executions; the pipeline copes with that.
resource "aws_cloudwatch_event_rule" "retrain_on_drift" {
  name        = "${var.project}-retrain-on-drift"
  description = "A prod model alarm went to ALARM: start the training pipeline. The gate and the approval still decide what reaches prod."

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = "${var.project}-prod-model-" }]
      state     = { value = ["ALARM"] }
    }
  })
}

# TriggerReason is the fixed word `drift`. The pipeline-parameter list of a SageMaker target takes static values only (this
# provider's block has no input transformer for it), so the rule cannot copy the alarm's name into the parameter. Which alarm
# fired is not lost: finrisk-ml asks CloudWatch (`DescribeAlarms`, finrisk-prod-model-*) when it starts the run.
resource "aws_cloudwatch_event_target" "retrain_pipeline" {
  rule      = aws_cloudwatch_event_rule.retrain_on_drift.name
  target_id = local.train_pipeline
  arn       = local.train_pipeline_arn
  role_arn  = aws_iam_role.events.arn

  sagemaker_pipeline_target {
    pipeline_parameter_list {
      name  = "TriggerReason"
      value = "drift"
    }
  }

  depends_on = [aws_iam_role_policy.events]
}

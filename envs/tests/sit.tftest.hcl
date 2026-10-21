# Offline test of sit (Lambda, like dev). Needs workspace "sit": bash scripts/tf_checks.sh envs

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
  env                = "sit"
  compute            = "lambda"
  log_retention_days = 14
  bucket_versioning  = false
}

run "sit_is_a_lambda_environment" {
  command = plan

  assert {
    condition     = length(aws_iam_role.ecs_execution) == 0 && length(aws_iam_role.ecs_infrastructure) == 0
    error_message = "sit (Lambda) must not create the ECS Express roles."
  }

  assert {
    condition     = aws_iam_role.runtime.name == "finrisk-sit-runtime" && aws_s3_bucket.env.bucket == "finrisk-sit-123456789012-ap-southeast-2-an"
    error_message = "sit names: finrisk-sit-runtime, finrisk-sit-<acct>-<region>-an."
  }

  assert {
    condition     = aws_cloudwatch_log_group.app.name == "/app/finrisk-sit" && aws_cloudwatch_log_group.app.retention_in_days == 14 && aws_s3_bucket.env.force_destroy == true
    error_message = "sit logs: /app/finrisk-sit, 14 days; destroy may empty the bucket."
  }

  assert {
    condition     = toset([for p in aws_ssm_parameter.env : p.name]) == toset(["/finrisk/sit/runtime_role_arn", "/finrisk/sit/log_group", "/finrisk/sit/bucket", "/finrisk/sit/endpoint_role_arn"]) && aws_ssm_parameter.model_pointer.name == "/finrisk/sit/model" && aws_ssm_parameter.index_pointer.name == "/finrisk/sit/index"
    error_message = "sit parameters."
  }
}

run "sit_runtime_role_reads_only_sit_and_shared" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_role_policy.runtime.policy, "parameter/finrisk/sit/*") && strcontains(aws_iam_role_policy.runtime.policy, "parameter/finrisk/shared/*") && !strcontains(aws_iam_role_policy.runtime.policy, "finrisk/dev") && !strcontains(aws_iam_role_policy.runtime.policy, "finrisk/prod") && !strcontains(aws_iam_role_policy.runtime.policy, "finrisk/pre-prod")
    error_message = "The sit runtime role reads /finrisk/sit/* and /finrisk/shared/* only."
  }
}

run "sit_endpoint_is_serverless_like_dev" {
  command = apply

  assert {
    condition = (
      aws_iam_role.endpoint.name == "finrisk-sit-endpoint" &&
      !strcontains(aws_iam_role_policy.endpoint.policy, "s3:Put") && !strcontains(aws_iam_role_policy.endpoint.policy, "capture") &&
      strcontains(aws_iam_role_policy.endpoint.policy, "/aws/sagemaker/Endpoints/finrisk-sit-fraud") &&
      !strcontains(aws_iam_role_policy.endpoint.policy, "finrisk-dev") &&
      strcontains(aws_iam_role_policy.runtime.policy, "endpoint/finrisk-sit-fraud") &&
      length(aws_cloudwatch_metric_alarm.endpoint) == 0 && length(aws_cloudwatch_metric_alarm.model_drift) == 0
    )
    error_message = "sit: serverless endpoint role without capture or alarms, and the app may call finrisk-sit-fraud only."
  }
}

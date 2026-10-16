# Offline test of the Lambda branch (dev and sit). No AWS account is touched: mock_provider fakes AWS.
#
# The workspace guard (main.tf) needs the workspace to be named like the env, and `terraform test` runs in whichever
# workspace is selected -- so this file needs workspace "dev". scripts/tf_checks.sh does that for you:
#   bash scripts/tf_checks.sh envs

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
  env                = "dev"
  compute            = "lambda"
  log_retention_days = 7
  bucket_versioning  = false
}

run "dev_has_no_ecs_roles" {
  command = plan

  assert {
    condition     = length(aws_iam_role.ecs_execution) == 0 && length(aws_iam_role.ecs_infrastructure) == 0 && length(aws_iam_role_policy_attachment.ecs_execution) == 0
    error_message = "dev (Lambda) must not create the ECS Express roles."
  }

  assert {
    condition     = aws_iam_role.runtime.name == "finrisk-dev-runtime"
    error_message = "The runtime role is finrisk-<env>-runtime."
  }
}

run "dev_bucket_and_logs" {
  command = plan

  assert {
    condition     = aws_s3_bucket.env.bucket == "finrisk-dev-123456789012-ap-southeast-2-an" && aws_s3_bucket.env.bucket_namespace == "account-regional"
    error_message = "The bucket is finrisk-<env>-<acct>-<region>-an."
  }

  assert {
    condition     = aws_s3_bucket.env.force_destroy == true && aws_s3_bucket_versioning.env.versioning_configuration[0].status == "Disabled"
    error_message = "dev: destroy may empty the bucket; versioning off."
  }

  assert {
    condition     = aws_cloudwatch_log_group.app.name == "/app/finrisk-dev" && aws_cloudwatch_log_group.app.retention_in_days == 7
    error_message = "dev logs: /app/finrisk-dev, 7 days."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.env.block_public_acls && aws_s3_bucket_public_access_block.env.block_public_policy && aws_s3_bucket_public_access_block.env.ignore_public_acls && aws_s3_bucket_public_access_block.env.restrict_public_buckets
    error_message = "The bucket blocks all public access."
  }
}

run "the_runtime_role_has_exactly_the_contract_permissions" {
  command = apply

  # Trust: the compute services only.
  assert {
    condition     = toset(jsondecode(aws_iam_role.runtime.assume_role_policy).Statement[0].Principal.Service) == toset(["lambda.amazonaws.com", "ecs-tasks.amazonaws.com"])
    error_message = "Lambda and ECS tasks may wear the runtime role; nobody else."
  }

  # Statement by statement.
  assert {
    condition = alltrue([
      for sid, resources in {
        "WriteOwnLogs"               = [format("%s:*", aws_cloudwatch_log_group.app.arn)]
        "ReadOwnBucket"              = [format("%s/*", aws_s3_bucket.env.arn)]
        "ReadModelArtifacts"         = ["arn:aws:s3:::finrisk-ml-123456789012-ap-southeast-2-an/models/*"]
        "ReadIndexArtifacts"         = ["arn:aws:s3:::finrisk-kb-123456789012-ap-southeast-2-an/indexes/*"]
        "InvokeBedrockModels"        = ["arn:aws:bedrock:ap-southeast-2::foundation-model/deepseek.v3.2", "arn:aws:bedrock:ap-southeast-2::foundation-model/amazon.titan-embed-text-v2:0"]
        "ReadPointersAndSharedNames" = ["arn:aws:ssm:ap-southeast-2:123456789012:parameter/finrisk/dev/*", "arn:aws:ssm:ap-southeast-2:123456789012:parameter/finrisk/shared/*"]
      } :
      toset(flatten([[for s in jsondecode(aws_iam_role_policy.runtime.policy).Statement : s.Resource if s.Sid == sid][0]])) == toset(resources)
    ])
    error_message = "The runtime role's resources are not exactly the ones of the contract (spec 3.3)."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.runtime.policy).Statement : s.Action if s.Sid == "ReadPointersAndSharedNames"][0] == ["ssm:GetParameter", "ssm:GetParameters"] &&
      [for s in jsondecode(aws_iam_role_policy.runtime.policy).Statement : s.Action if s.Sid == "ReadModelArtifacts"][0] == ["s3:GetObject"] &&
      [for s in jsondecode(aws_iam_role_policy.runtime.policy).Statement : s.Action if s.Sid == "ReadIndexArtifacts"][0] == ["s3:GetObject"]
    )
    error_message = "Parameters and artifacts are read-only for the running app."
  }

  # Nothing writes except logs; nothing is "*".
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.runtime.policy).Statement :
      s.Resource != "*" && alltrue([for a in tolist(s.Action) : can(regex("^(s3:(Get|List)|ssm:Get|logs:(CreateLogStream|PutLogEvents)|bedrock:Invoke)", a))])
    ])
    error_message = "The runtime role may only read, write its own log and invoke Bedrock models."
  }

  # Only the two models: not every foundation model, not an inference profile.
  assert {
    condition     = !strcontains(aws_iam_role_policy.runtime.policy, "foundation-model/*") && !strcontains(aws_iam_role_policy.runtime.policy, "inference-profile")
    error_message = "The runtime role may call exactly the chat and embedding models."
  }

  # No other environment, no other bucket, no write to the model or index.
  assert {
    condition     = !strcontains(aws_iam_role_policy.runtime.policy, "finrisk/prod") && !strcontains(aws_iam_role_policy.runtime.policy, "finrisk/sit") && !strcontains(aws_iam_role_policy.runtime.policy, "s3:Put") && !strcontains(aws_iam_role_policy.runtime.policy, "ssm:Put")
    error_message = "The dev runtime role reads only dev's and the shared parameters and writes no data."
  }
}

run "ssm_parameters_of_a_lambda_environment" {
  command = plan

  assert {
    condition = toset([for p in aws_ssm_parameter.env : p.name]) == toset([
      "/finrisk/dev/runtime_role_arn", "/finrisk/dev/log_group", "/finrisk/dev/bucket",
    ])
    error_message = "A Lambda environment publishes runtime_role_arn, log_group and bucket (no ecs_* roles)."
  }

  assert {
    condition     = aws_ssm_parameter.model_pointer.name == "/finrisk/dev/model" && aws_ssm_parameter.index_pointer.name == "/finrisk/dev/index"
    error_message = "The pointers are /finrisk/<env>/model and /finrisk/<env>/index."
  }

  assert {
    condition     = nonsensitive(aws_ssm_parameter.env["log_group"].value) == "/app/finrisk-dev" && nonsensitive(aws_ssm_parameter.env["bucket"].value) == "finrisk-dev-123456789012-ap-southeast-2-an"
    error_message = "A parameter holds the value of the thing it is named after."
  }
}

run "the_pointers_start_as_null_versions" {
  command = plan

  assert {
    condition     = nonsensitive(aws_ssm_parameter.model_pointer.value) == "{\"version\": null}" && nonsensitive(aws_ssm_parameter.index_pointer.value) == "{\"version\": null}"
    error_message = "A new pointer says {\"version\": null}: nothing promoted yet."
  }

  assert {
    condition     = jsondecode(nonsensitive(aws_ssm_parameter.model_pointer.value)).version == null
    error_message = "The pointer must be valid JSON with version null."
  }
}

# The point of ignore_changes: first apply creates the pointers; a later apply with a DIFFERENT seed (what a pipeline
# promotion looks like from Terraform's side: the live value no longer equals the code's) changes nothing.
run "first_apply_creates_the_pointers" {
  command = apply
}

run "a_second_apply_never_touches_a_promoted_pointer" {
  command = plan

  variables {
    pointer_seed = "{\"version\": 7, \"status\": \"Approved\"}"
  }

  assert {
    condition     = nonsensitive(aws_ssm_parameter.model_pointer.value) == "{\"version\": null}" && nonsensitive(aws_ssm_parameter.index_pointer.value) == "{\"version\": null}"
    error_message = "ignore_changes = [value]: the planned value must stay what the first apply wrote, whatever the code says now."
  }
}

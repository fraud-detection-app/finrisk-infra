# Offline test of the ECS Express Mode branch (pre-prod). Needs workspace "pre-prod": bash scripts/tf_checks.sh envs

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
  env                = "pre-prod"
  compute            = "ecs"
  log_retention_days = 30
  bucket_versioning  = true
}

run "pre_prod_creates_the_two_express_roles" {
  command = plan

  assert {
    condition     = length(aws_iam_role.ecs_execution) == 1 && length(aws_iam_role.ecs_infrastructure) == 1 && length(aws_iam_role_policy_attachment.ecs_execution) == 1 && length(aws_iam_role_policy_attachment.ecs_infrastructure) == 1
    error_message = "pre-prod (ECS) needs the execution and infrastructure roles with their managed policies."
  }

  assert {
    condition     = aws_iam_role.ecs_execution[0].name == "finrisk-pre-prod-ecs-execution" && aws_iam_role.ecs_infrastructure[0].name == "finrisk-pre-prod-ecs-infrastructure" && aws_iam_role.runtime.name == "finrisk-pre-prod-runtime"
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

run "pre_prod_bucket_logs_and_parameters" {
  command = plan

  assert {
    condition     = aws_s3_bucket.env.bucket == "finrisk-pre-prod-123456789012-ap-southeast-2-an" && aws_s3_bucket.env.force_destroy != true && aws_s3_bucket_versioning.env.versioning_configuration[0].status == "Enabled"
    error_message = "pre-prod: versioned bucket that destroy never empties."
  }

  assert {
    condition     = aws_cloudwatch_log_group.app.name == "/app/finrisk-pre-prod" && aws_cloudwatch_log_group.app.retention_in_days == 30
    error_message = "pre-prod logs: /app/finrisk-pre-prod, 30 days."
  }

  assert {
    condition = toset([for p in aws_ssm_parameter.env : p.name]) == toset([
      "/finrisk/pre-prod/runtime_role_arn", "/finrisk/pre-prod/log_group", "/finrisk/pre-prod/bucket",
      "/finrisk/pre-prod/ecs_execution_role_arn", "/finrisk/pre-prod/ecs_infrastructure_role_arn",
    ])
    error_message = "An ECS environment also publishes ecs_execution_role_arn and ecs_infrastructure_role_arn."
  }

  assert {
    condition     = aws_ssm_parameter.model_pointer.name == "/finrisk/pre-prod/model" && aws_ssm_parameter.index_pointer.name == "/finrisk/pre-prod/index"
    error_message = "The pointers are /finrisk/<env>/model and /index."
  }
}

run "pre_prod_runtime_role_reads_only_its_own_and_shared" {
  command = apply

  assert {
    condition = (
      strcontains(aws_iam_role_policy.runtime.policy, "parameter/finrisk/pre-prod/*") && strcontains(aws_iam_role_policy.runtime.policy, "parameter/finrisk/shared/*") &&
      !strcontains(aws_iam_role_policy.runtime.policy, "finrisk/dev") && !strcontains(aws_iam_role_policy.runtime.policy, "finrisk/sit")
    )
    error_message = "The pre-prod runtime role reads /finrisk/pre-prod/* and /finrisk/shared/* only."
  }
}

run "pre_prod_pointers_ignore_a_promoted_value" {
  command = apply
}

run "pre_prod_second_apply_keeps_the_pointer" {
  command = plan

  variables {
    pointer_seed = "{\"version\": 3}"
  }

  assert {
    condition     = nonsensitive(aws_ssm_parameter.model_pointer.value) == "{\"version\": null}"
    error_message = "ignore_changes = [value] keeps what the first apply wrote."
  }
}

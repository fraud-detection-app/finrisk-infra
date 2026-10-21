# Offline test of the guard rails: bad input must stop the plan. Runs in the "dev" workspace (a workspace that matches
# the valid env used below):  bash scripts/tf_checks.sh envs

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

# The matching case first: workspace dev + env dev is fine.
run "the_matching_workspace_is_accepted" {
  command = plan

  variables {
    env     = "dev"
    compute = "lambda"
  }

  assert {
    condition     = terraform.workspace == "dev"
    error_message = "This file must run in the dev workspace."
  }
}

# prod's settings in the dev workspace: the precondition in main.tf stops the plan, so nothing could be written into
# the wrong state file.
run "wrong_workspace_is_blocked" {
  command = plan

  variables {
    env     = "prod"
    compute = "ecs"
  }

  expect_failures = [terraform_data.workspace_matches_env]
}

run "every_other_environment_is_blocked_in_the_dev_workspace" {
  command = plan

  variables {
    env     = "pre-prod"
    compute = "ecs"
  }

  expect_failures = [terraform_data.workspace_matches_env]
}

run "staging_is_not_an_environment" {
  command = plan

  variables {
    env     = "staging"
    compute = "lambda"
  }

  expect_failures = [var.env]
}

run "fargate_is_not_a_compute_choice" {
  command = plan

  variables {
    env     = "dev"
    compute = "fargate"
  }

  expect_failures = [var.compute]
}

# Offline test of shared/. mock_provider fakes AWS: nothing is created, no account or credentials are needed.
#
#   bash scripts/tf_checks.sh shared
#
# What it proves: the registries are IMMUTABLE, scanned and keep the last 10 (finrisk-app lets only finrisk-* Lambda functions pull); the buckets have the contract names and
# are private and versioned; the SageMaker role is least privilege; the SSM names are exactly the contract's.
# (bootstrap/tests/trust.tftest.hcl asserts the same bucket, repository and role names from the other side.)

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

run "two_registries_immutable_scanned_and_pruned" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this["app"].name == "finrisk-app" && aws_ecr_repository.this["train"].name == "finrisk-train" && length(aws_ecr_repository.this) == 2
    error_message = "Exactly two repositories: finrisk-app and finrisk-train."
  }

  assert {
    condition = alltrue([
      for k, r in aws_ecr_repository.this :
      r.image_tag_mutability == "IMMUTABLE" && r.image_scanning_configuration[0].scan_on_push == true
    ])
    error_message = "Both repositories must be IMMUTABLE with scan on push."
  }

  assert {
    condition = alltrue([
      for k, p in aws_ecr_lifecycle_policy.this :
      jsondecode(p.policy).rules[0].selection.countNumber == 10 && jsondecode(p.policy).rules[0].selection.countType == "imageCountMoreThan" && jsondecode(p.policy).rules[0].action.type == "expire"
    ])
    error_message = "Both repositories keep the last 10 images."
  }
}

run "lambda_may_pull_the_app_image_and_nothing_else" {
  command = apply

  assert {
    condition     = aws_ecr_repository_policy.lambda_pull.repository == "finrisk-app"
    error_message = "The pull policy goes on finrisk-app only."
  }

  assert {
    condition     = length(jsondecode(aws_ecr_repository_policy.lambda_pull.policy).Statement) == 1
    error_message = "One statement: Lambda pull. Nothing else (ECS and SageMaker pull with their roles)."
  }

  assert {
    condition = (
      jsondecode(aws_ecr_repository_policy.lambda_pull.policy).Statement[0].Sid == "LambdaPullForFinriskFunctions" &&
      jsondecode(aws_ecr_repository_policy.lambda_pull.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_ecr_repository_policy.lambda_pull.policy).Statement[0].Principal == { Service = "lambda.amazonaws.com" } &&
      toset(jsondecode(aws_ecr_repository_policy.lambda_pull.policy).Statement[0].Action) == toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"])
    )
    error_message = "Only the Lambda service, only BatchGetImage and GetDownloadUrlForLayer."
  }

  assert {
    condition     = jsondecode(aws_ecr_repository_policy.lambda_pull.policy).Statement[0].Condition == { StringLike = { "aws:sourceArn" = "arn:aws:lambda:ap-southeast-2:123456789012:function:finrisk-*" } }
    error_message = "Only finrisk-* functions of this account and Region may use it."
  }
}

run "the_keep_count_can_change" {
  command = plan

  variables {
    keep_images = 25
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this["app"].policy).rules[0].selection.countNumber == 25
    error_message = "keep_images should reach the lifecycle policy."
  }
}

run "buckets_have_the_contract_names_and_are_private_and_versioned" {
  command = plan

  assert {
    condition     = aws_s3_bucket.ml.bucket == "finrisk-ml-123456789012-ap-southeast-2-an" && aws_s3_bucket.kb.bucket == "finrisk-kb-123456789012-ap-southeast-2-an"
    error_message = "ML and KB bucket names: finrisk-ml-<acct>-<region>-an and finrisk-kb-<acct>-<region>-an."
  }

  assert {
    condition     = aws_s3_bucket.ml.bucket_namespace == "account-regional" && aws_s3_bucket.kb.bucket_namespace == "account-regional"
    error_message = "Buckets use the account-regional namespace."
  }

  assert {
    condition     = aws_s3_bucket_versioning.ml.versioning_configuration[0].status == "Enabled" && aws_s3_bucket_versioning.kb.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning on for both buckets."
  }

  assert {
    condition = alltrue([
      for b in [aws_s3_bucket_public_access_block.ml, aws_s3_bucket_public_access_block.kb] :
      b.block_public_acls && b.block_public_policy && b.ignore_public_acls && b.restrict_public_buckets
    ])
    error_message = "Both buckets block all public access."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.ml.rule[0].noncurrent_version_expiration[0].noncurrent_days == 30 && aws_s3_bucket_lifecycle_configuration.kb.rule[0].noncurrent_version_expiration[0].noncurrent_days == 30
    error_message = "Old versions expire after 30 days."
  }

  # Not force_destroy: destroying shared/ must not silently delete models or indexes.
  assert {
    condition     = aws_s3_bucket.ml.force_destroy != true && aws_s3_bucket.kb.force_destroy != true
    error_message = "The ML and KB buckets must not be force_destroy."
  }
}

run "the_model_registry_group_has_the_contract_name" {
  command = plan

  assert {
    condition     = aws_sagemaker_model_package_group.model.model_package_group_name == "finrisk-fraud-model"
    error_message = "The model package group is finrisk-fraud-model."
  }

  assert {
    condition     = aws_iam_role.sagemaker_exec.name == "finrisk-sagemaker-exec"
    error_message = "The SageMaker execution role is finrisk-sagemaker-exec."
  }
}

run "the_sagemaker_role_is_least_privilege" {
  command = apply

  assert {
    condition     = jsondecode(aws_iam_role.sagemaker_exec.assume_role_policy).Statement[0].Principal.Service == "sagemaker.amazonaws.com" && jsondecode(aws_iam_role.sagemaker_exec.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012"
    error_message = "Only SageMaker, for this account, may wear the role."
  }

  # Statement by statement: data is READ only, models/metrics are WRITE only, ECR pull is the training repository.
  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "ReadTrainingData"][0].Action == ["s3:GetObject"] &&
      endswith([for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "ReadTrainingData"][0].Resource, "/data/*") &&
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "WriteModelsAndMetrics"][0].Action == ["s3:PutObject", "s3:AbortMultipartUpload"] &&
      length([for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "WriteModelsAndMetrics"][0].Resource) == 2
    )
    error_message = "data/ is read-only; models/ and metrics/ are write-only."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "PullTheTrainingImage"][0].Resource == aws_ecr_repository.this["train"].arn &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "ecr:PutImage") &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "s3:DeleteObject") &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "sagemaker:")
    )
    error_message = "Pull from finrisk-train only; no push, no delete, no SageMaker API."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.sagemaker_exec.policy, "/aws/sagemaker/TrainingJobs") && strcontains(aws_iam_role_policy.sagemaker_exec.policy, "cloudwatch:namespace")
    error_message = "Logs go to the training log group; metrics only to SageMaker's namespace."
  }
}

run "ssm_names_are_exactly_the_contract" {
  command = plan

  assert {
    condition = toset([for p in aws_ssm_parameter.shared : p.name]) == toset([
      "/finrisk/shared/ecr_app_url",
      "/finrisk/shared/ecr_train_url",
      "/finrisk/shared/ml_bucket",
      "/finrisk/shared/kb_bucket",
      "/finrisk/shared/sagemaker_role_arn",
      "/finrisk/shared/model_package_group",
    ])
    error_message = "The /finrisk/shared/* parameters are the contract (spec 3.1): do not rename one."
  }

  assert {
    condition     = alltrue([for p in aws_ssm_parameter.shared : p.type == "String"])
    error_message = "Shared parameters are plain Strings (none is a secret)."
  }
}

run "ssm_values_are_what_they_name" {
  command = apply

  assert {
    condition = (
      aws_ssm_parameter.shared["ml_bucket"].value == aws_s3_bucket.ml.bucket &&
      aws_ssm_parameter.shared["kb_bucket"].value == aws_s3_bucket.kb.bucket &&
      aws_ssm_parameter.shared["ecr_app_url"].value == aws_ecr_repository.this["app"].repository_url &&
      aws_ssm_parameter.shared["ecr_train_url"].value == aws_ecr_repository.this["train"].repository_url &&
      aws_ssm_parameter.shared["sagemaker_role_arn"].value == aws_iam_role.sagemaker_exec.arn &&
      aws_ssm_parameter.shared["model_package_group"].value == "finrisk-fraud-model"
    )
    error_message = "Each parameter must hold the value of the resource it is named after."
  }
}

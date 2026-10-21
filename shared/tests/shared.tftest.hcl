# Offline test of shared/. mock_provider fakes AWS: nothing is created, no account or credentials are needed.
#
#   bash scripts/tf_checks.sh shared
#
# What it proves: the registries are IMMUTABLE, scanned and keep the last 10 (finrisk-app lets only finrisk-* Lambda functions pull); the buckets have the contract names and
# are private and versioned (and the ML bucket never expires raw/, labels/, feature-store/, replay/); the SageMaker role is least
# privilege; the Feature Store group, the Glue tables, the Athena workgroup, the MLflow App, the schedules, the retrain-on-drift
# rule and the Studio domain are what week 13b says; the SSM names are exactly the contract's.
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

# The mock invents random strings for computed attributes. Several resources validate an ARN, so the roles (and the MLflow App
# and the model group, which policies and tests refer to) get realistic, DIFFERENT ARNs here.
override_resource {
  target = aws_iam_role.sagemaker_exec
  values = { arn = "arn:aws:iam::123456789012:role/finrisk-sagemaker-exec" }
}

override_resource {
  target = aws_iam_role.mlflow
  values = { arn = "arn:aws:iam::123456789012:role/finrisk-mlflow" }
}

override_resource {
  target = aws_iam_role.scheduler
  values = { arn = "arn:aws:iam::123456789012:role/finrisk-scheduler" }
}

override_resource {
  target = aws_iam_role.events
  values = { arn = "arn:aws:iam::123456789012:role/finrisk-events" }
}

override_resource {
  target = aws_iam_role.studio[0]
  values = { arn = "arn:aws:iam::123456789012:role/finrisk-studio" }
}

override_resource {
  target = aws_sagemaker_mlflow_app.this
  values = { arn = "arn:aws:sagemaker:ap-southeast-2:123456789012:mlflow-app/app-MOCK1234" }
}

override_resource {
  target = aws_sagemaker_model_package_group.model
  values = { arn = "arn:aws:sagemaker:ap-southeast-2:123456789012:model-package-group/finrisk-fraud-model" }
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
    condition     = aws_s3_bucket_lifecycle_configuration.kb.rule[0].noncurrent_version_expiration[0].noncurrent_days == 30
    error_message = "Old versions of KB files expire after 30 days."
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

run "the_ml_bucket_never_expires_raw_labels_feature_store_or_replay" {
  command = plan

  # One rule per folder that MAY expire (S3 filters on one prefix); the four folders that are lineage have none.
  assert {
    condition = toset([for r in aws_s3_bucket_lifecycle_configuration.ml.rule : r.id if startswith(r.id, "expire-old-versions-")]) == toset([
      "expire-old-versions-data", "expire-old-versions-datasets", "expire-old-versions-models", "expire-old-versions-metrics",
      "expire-old-versions-monitoring", "expire-old-versions-capture", "expire-old-versions-athena", "expire-old-versions-mlflow",
    ])
    error_message = "Only data, datasets, models, metrics, monitoring, capture, athena and mlflow may expire old versions."
  }

  assert {
    condition = alltrue([
      for r in aws_s3_bucket_lifecycle_configuration.ml.rule :
      !contains(["raw/", "labels/", "feature-store/", "replay/"], try(r.filter[0].prefix, "")) &&
      (r.id == "abort-unfinished-uploads" || (r.noncurrent_version_expiration[0].noncurrent_days == 30 && endswith(r.filter[0].prefix, "/")))
    ])
    error_message = "raw/, labels/, feature-store/ and replay/ have no expiry rule; every other rule keeps 30 days and names a folder."
  }

  # No rule expires CURRENT objects anywhere in the bucket.
  assert {
    condition     = alltrue([for r in aws_s3_bucket_lifecycle_configuration.ml.rule : length(r.expiration) == 0])
    error_message = "No rule deletes current objects."
  }

  assert {
    condition     = one([for r in aws_s3_bucket_lifecycle_configuration.ml.rule : r if r.id == "abort-unfinished-uploads"]).abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "Unfinished uploads (the 493 MB CSV!) are cleaned up after 7 days."
  }
}

run "the_sagemaker_role_is_least_privilege" {
  command = apply

  assert {
    condition     = jsondecode(aws_iam_role.sagemaker_exec.assume_role_policy).Statement[0].Principal.Service == "sagemaker.amazonaws.com" && jsondecode(aws_iam_role.sagemaker_exec.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012"
    error_message = "Only SageMaker, for this account, may wear the role."
  }

  # Folder by folder: capture/ and data/ are read-only; the others can be written; nothing can be deleted.
  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "ReadTheMlBucketFolders"][0].Action == ["s3:GetObject"] &&
      toset([for r in [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "ReadTheMlBucketFolders"][0].Resource : reverse(split("/", trimsuffix(r, "/*")))[0]]) == toset(["raw", "data", "datasets", "labels", "replay", "models", "metrics", "monitoring", "capture", "athena", "feature-store", "mlflow"]) &&
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "WriteTheMlBucketFolders"][0].Action == ["s3:PutObject", "s3:AbortMultipartUpload"] &&
      toset([for r in [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "WriteTheMlBucketFolders"][0].Resource : reverse(split("/", trimsuffix(r, "/*")))[0]]) == toset(["raw", "datasets", "labels", "replay", "models", "metrics", "monitoring", "athena", "feature-store", "mlflow"])
    )
    error_message = "Read: every folder. Write: every folder except data/ and capture/ (read-only there)."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if s.Sid == "PullTheTrainingImage"][0].Resource == aws_ecr_repository.this["train"].arn &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "ecr:PutImage") &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "s3:DeleteObject") &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "UpdateModelPackage") &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "ssm:Put") &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "Endpoint") &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "iam:CreateRole")
    )
    error_message = "Pull from finrisk-train only; no push, no delete, no approving, no endpoint, no pointer."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.sagemaker_exec.policy, "/aws/sagemaker/TrainingJobs") && strcontains(aws_iam_role_policy.sagemaker_exec.policy, "/aws/sagemaker/ProcessingJobs")
    error_message = "Training and processing jobs write their own log groups."
  }

  # Metrics: only SageMaker's job namespaces and OUR monitor's.
  assert {
    condition     = toset([for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Condition.StringEquals["cloudwatch:namespace"] if s.Sid == "PublishMetrics"][0]) == toset(["/aws/sagemaker/TrainingJobs", "/aws/sagemaker/ProcessingJobs", "FinRisk/Model"])
    error_message = "PutMetricData only into /aws/sagemaker/TrainingJobs, /aws/sagemaker/ProcessingJobs and FinRisk/Model."
  }

  # Jobs: the three kinds the pipelines start, in this account and Region only. Not name-scoped: SageMaker Pipelines
  # names its jobs itself (pipelines-<execution id>-<step>-<random>), which a finrisk-* rule refused on the first live run.
  assert {
    condition = (
      toset([for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Resource if s.Sid == "RunTheJobsThePipelinesStart"][0]) == toset([
        "arn:aws:sagemaker:ap-southeast-2:123456789012:processing-job/*",
        "arn:aws:sagemaker:ap-southeast-2:123456789012:training-job/*",
        "arn:aws:sagemaker:ap-southeast-2:123456789012:hyper-parameter-tuning-job/*",
      ]) &&
      strcontains(aws_iam_role_policy.sagemaker_exec.policy, "sagemaker:CreateHyperParameterTuningJob") &&
      strcontains(aws_iam_role_policy.sagemaker_exec.policy, "sagemaker:StopProcessingJob") &&
      !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "arn:aws:sagemaker:ap-southeast-2:123456789012:*")
    )
    error_message = "Processing, training and tuning jobs (any name: Pipelines chooses them) can be created, described, stopped and tagged; nothing wider."
  }

  # Registry: create + read in the ONE group; PassRole only itself, only to SageMaker.
  assert {
    condition = (
      strcontains(aws_iam_role_policy.sagemaker_exec.policy, "sagemaker:CreateModelPackage") &&
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Resource if s.Sid == "PassItselfToTheJobsItStarts"][0] == aws_iam_role.sagemaker_exec.arn &&
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Condition if s.Sid == "PassItselfToTheJobsItStarts"][0] == { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } } &&
      length([for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s if contains(tolist(s.Action), "iam:PassRole")]) == 1
    )
    error_message = "Register in finrisk-fraud-model; PassRole only on itself, only to sagemaker.amazonaws.com."
  }

  # Feature Store, Athena, Glue, MLflow, SSM.
  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Action if s.Sid == "WriteRecordsToTheFeatureGroup"][0] == ["sagemaker:BatchWriteRecord", "sagemaker:PutRecord", "sagemaker:DescribeFeatureGroup"] &&
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Resource if s.Sid == "WriteRecordsToTheFeatureGroup"][0] == "arn:aws:sagemaker:ap-southeast-2:123456789012:feature-group/finrisk-transactions" &&
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Resource if s.Sid == "QueryInTheFinriskWorkgroup"][0] == "arn:aws:athena:ap-southeast-2:123456789012:workgroup/finrisk" &&
      toset([for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Action if s.Sid == "QueryInTheFinriskWorkgroup"][0]) == toset(["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:StopQueryExecution", "athena:GetWorkGroup"]) &&
      strcontains(aws_iam_role_policy.sagemaker_exec.policy, "database/finrisk_ml") &&
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Resource if s.Sid == "KeepTheFeatureStoreTable"][0][2] == "arn:aws:glue:ap-southeast-2:123456789012:table/finrisk_ml/transactions" &&
      [for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Action if s.Sid == "LogToTheMlflowApp"][0] == ["sagemaker:CallMlflowAppApi", "sagemaker:DescribeMlflowApp"] &&
      toset([for s in jsondecode(aws_iam_role_policy.sagemaker_exec.policy).Statement : s.Resource if s.Sid == "ReadSharedNamesAndTheProdModelPointer"][0]) == toset(["arn:aws:ssm:ap-southeast-2:123456789012:parameter/finrisk/shared/*", "arn:aws:ssm:ap-southeast-2:123456789012:parameter/finrisk/prod/model"])
    )
    error_message = "Feature Store (one group), Athena (one workgroup), Glue (finrisk_ml; create/update/delete only the transactions table), MLflow (sagemaker:CallMlflowAppApi), SSM (shared + the prod pointer)."
  }

  # No service-wide wildcard, and the whole policy fits in IAM's 10,240 characters.
  assert {
    condition     = !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "\"sagemaker:*\"") && !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "\"s3:*\"") && !strcontains(aws_iam_role_policy.sagemaker_exec.policy, "\"iam:*\"") && length(aws_iam_role_policy.sagemaker_exec.policy) < 9000
    error_message = "No service-wide wildcard; the execution role's policy stays under 9,000 characters (IAM's limit is 10,240)."
  }
}

run "the_feature_group_is_offline_only_with_the_contract_columns" {
  command = apply

  assert {
    condition = (
      aws_sagemaker_feature_group.transactions.feature_group_name == "finrisk-transactions" &&
      aws_sagemaker_feature_group.transactions.record_identifier_feature_name == "row_id" &&
      aws_sagemaker_feature_group.transactions.event_time_feature_name == "event_time" &&
      aws_sagemaker_feature_group.transactions.role_arn == aws_iam_role.sagemaker_exec.arn
    )
    error_message = "Group finrisk-transactions: record id row_id, event time event_time, written with the execution role."
  }

  # The columns, in order: the contract with finrisk-app's FEATURE_COLUMNS (spec 2.4).
  assert {
    condition = [for f in aws_sagemaker_feature_group.transactions.feature_definition : f.feature_name] == [
      "row_id", "event_time", "step", "transaction_type", "origin_customer",
      "amount", "log_amount", "origin_old_balance", "origin_new_balance", "destination_old_balance", "destination_new_balance",
      "origin_balance_delta", "destination_balance_delta", "amount_to_origin_balance",
      "hour_of_day", "tx_index_for_origin", "customer_tx_count_so_far", "customer_amount_so_far",
    ]
    error_message = "The 18 feature names, in this order, are the contract."
  }

  assert {
    condition = alltrue([
      for f in aws_sagemaker_feature_group.transactions.feature_definition :
      f.feature_type == lookup({
        row_id = "String", event_time = "String", transaction_type = "String", origin_customer = "String",
        step   = "Integral", hour_of_day = "Integral", tx_index_for_origin = "Integral", customer_tx_count_so_far = "Integral",
      }, f.feature_name, "Fractional")
    ])
    error_message = "Integral: step, hour_of_day, tx_index_for_origin, customer_tx_count_so_far. String: the four text columns. Everything else Fractional."
  }

  # Offline only: Glue table finrisk_ml.transactions, files in feature-store/, no online store.
  assert {
    condition = (
      length(aws_sagemaker_feature_group.transactions.online_store_config) == 0 &&
      aws_sagemaker_feature_group.transactions.offline_store_config[0].table_format == "Glue" &&
      aws_sagemaker_feature_group.transactions.offline_store_config[0].s3_storage_config[0].s3_uri == "s3://${aws_s3_bucket.ml.bucket}/feature-store/" &&
      aws_sagemaker_feature_group.transactions.offline_store_config[0].data_catalog_config[0].database == "finrisk_ml" &&
      aws_sagemaker_feature_group.transactions.offline_store_config[0].data_catalog_config[0].table_name == "transactions" &&
      aws_sagemaker_feature_group.transactions.offline_store_config[0].data_catalog_config[0].catalog == "AwsDataCatalog" &&
      aws_sagemaker_feature_group.transactions.offline_store_config[0].disable_glue_table_creation != true
    )
    error_message = "Offline store only: Glue table finrisk_ml.transactions over s3://<ml bucket>/feature-store/; no online store."
  }
}

run "glue_database_labels_table_and_athena_workgroup" {
  command = apply

  assert {
    condition     = aws_glue_catalog_database.ml.name == "finrisk_ml" && aws_glue_catalog_table.labels.name == "labels" && aws_glue_catalog_table.labels.database_name == "finrisk_ml"
    error_message = "Database finrisk_ml, table labels."
  }

  assert {
    condition = (
      aws_glue_catalog_table.labels.storage_descriptor[0].location == "s3://${aws_s3_bucket.ml.bucket}/labels/" &&
      [for c in aws_glue_catalog_table.labels.storage_descriptor[0].columns : "${c.name}:${c.type}"] == ["row_id:string", "is_fraud:int", "event_time:string", "label_time:string", "source:string", "batch_id:string"] &&
      length(aws_glue_catalog_table.labels.partition_keys) == 0 &&
      aws_glue_catalog_table.labels.parameters["classification"] == "parquet" &&
      aws_glue_catalog_table.labels.storage_descriptor[0].ser_de_info[0].serialization_library == "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    )
    error_message = "labels: parquet over s3://<ml>/labels/, six columns, no partition keys (spec 2.6)."
  }

  assert {
    condition = (
      aws_athena_workgroup.finrisk.name == "finrisk" &&
      aws_athena_workgroup.finrisk.force_destroy == true &&
      aws_athena_workgroup.finrisk.configuration[0].enforce_workgroup_configuration == true &&
      aws_athena_workgroup.finrisk.configuration[0].bytes_scanned_cutoff_per_query == 10737418240 &&
      aws_athena_workgroup.finrisk.configuration[0].result_configuration[0].output_location == "s3://${aws_s3_bucket.ml.bucket}/athena/"
    )
    error_message = "Workgroup finrisk: results enforced into athena/, 10 GB cutoff per query, force_destroy so teardown works."
  }
}

run "the_cutoff_and_flags_can_change" {
  command = plan

  variables {
    athena_bytes_scanned_cutoff = 5368709120
    weekly_retrain_enabled      = false
  }

  assert {
    condition     = aws_athena_workgroup.finrisk.configuration[0].bytes_scanned_cutoff_per_query == 5368709120 && aws_scheduler_schedule.weekly_retrain.state == "DISABLED"
    error_message = "The cutoff and the weekly switch are variables."
  }
}

run "mlflow_app_and_its_role" {
  command = apply

  assert {
    condition = (
      aws_sagemaker_mlflow_app.this.name == "finrisk-mlflow" &&
      aws_sagemaker_mlflow_app.this.artifact_store_uri == "s3://${aws_s3_bucket.ml.bucket}/mlflow/" &&
      aws_sagemaker_mlflow_app.this.role_arn == aws_iam_role.mlflow.arn &&
      aws_sagemaker_mlflow_app.this.model_registration_mode == "AutoModelRegistrationDisabled" &&
      aws_iam_role.mlflow.name == "finrisk-mlflow"
    )
    error_message = "MLflow App finrisk-mlflow, artifacts in s3://<ml>/mlflow/, wearing role finrisk-mlflow, no automatic registration."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.mlflow.assume_role_policy).Statement[0].Principal.Service == "sagemaker.amazonaws.com" &&
      [for s in jsondecode(aws_iam_role_policy.mlflow.policy).Statement : s.Resource if s.Sid == "ArtifactsInTheMlflowFolder"][0] == "${aws_s3_bucket.ml.arn}/mlflow/*" &&
      !strcontains(aws_iam_role_policy.mlflow.policy, "sagemaker:") &&
      !strcontains(aws_iam_role_policy.mlflow.policy, "s3:DeleteObject") &&
      !strcontains(aws_iam_role_policy.mlflow.policy, "/models/")
    )
    error_message = "The MLflow role reaches the mlflow/ folder only: no registry, no models/, no delete."
  }
}

run "the_schedules_and_the_retrain_on_drift_rule" {
  command = apply

  assert {
    condition = (
      aws_scheduler_schedule_group.this.name == "finrisk" &&
      aws_scheduler_schedule.weekly_retrain.name == "finrisk-weekly-retrain" && aws_scheduler_schedule.weekly_retrain.group_name == "finrisk" &&
      aws_scheduler_schedule.weekly_retrain.state == "ENABLED" &&
      aws_scheduler_schedule.weekly_retrain.schedule_expression == "cron(0 2 ? * MON *)" &&
      aws_scheduler_schedule.weekly_retrain.schedule_expression_timezone == "Australia/Sydney" &&
      aws_scheduler_schedule.weekly_retrain.target[0].arn == "arn:aws:sagemaker:ap-southeast-2:123456789012:pipeline/finrisk-train" &&
      aws_scheduler_schedule.weekly_retrain.target[0].role_arn == aws_iam_role.scheduler.arn &&
      [for p in aws_scheduler_schedule.weekly_retrain.target[0].sagemaker_pipeline_parameters[0].pipeline_parameter : "${p.name}=${p.value}"] == ["TriggerReason=schedule"]
    )
    error_message = "finrisk-weekly-retrain: Monday 02:00 Sydney, ENABLED, starts finrisk-train with TriggerReason=schedule."
  }

  # The hourly monitor exists but is OFF unless monitor_schedule_enabled = true.
  assert {
    condition = (
      aws_scheduler_schedule.hourly_monitor.name == "finrisk-hourly-monitor" &&
      aws_scheduler_schedule.hourly_monitor.state == "DISABLED" &&
      aws_scheduler_schedule.hourly_monitor.schedule_expression == "rate(1 hour)" &&
      aws_scheduler_schedule.hourly_monitor.target[0].arn == "arn:aws:sagemaker:ap-southeast-2:123456789012:pipeline/finrisk-monitor" &&
      [for p in aws_scheduler_schedule.hourly_monitor.target[0].sagemaker_pipeline_parameters[0].pipeline_parameter : "${p.name}=${p.value}"] == ["Env=prod"]
    )
    error_message = "finrisk-hourly-monitor is DISABLED by default and starts finrisk-monitor with Env=prod."
  }

  # The rule: a finrisk-prod-model-* alarm going to ALARM -> finrisk-train, TriggerReason=drift.
  assert {
    condition = (
      aws_cloudwatch_event_rule.retrain_on_drift.name == "finrisk-retrain-on-drift" &&
      jsondecode(aws_cloudwatch_event_rule.retrain_on_drift.event_pattern).source == ["aws.cloudwatch"] &&
      jsondecode(aws_cloudwatch_event_rule.retrain_on_drift.event_pattern)["detail-type"] == ["CloudWatch Alarm State Change"] &&
      jsondecode(aws_cloudwatch_event_rule.retrain_on_drift.event_pattern).detail.alarmName == [{ prefix = "finrisk-prod-model-" }] &&
      jsondecode(aws_cloudwatch_event_rule.retrain_on_drift.event_pattern).detail.state.value == ["ALARM"]
    )
    error_message = "The rule matches a CloudWatch alarm state change to ALARM for alarm names starting finrisk-prod-model-."
  }

  assert {
    condition = (
      aws_cloudwatch_event_target.retrain_pipeline.rule == "finrisk-retrain-on-drift" &&
      aws_cloudwatch_event_target.retrain_pipeline.arn == "arn:aws:sagemaker:ap-southeast-2:123456789012:pipeline/finrisk-train" &&
      aws_cloudwatch_event_target.retrain_pipeline.role_arn == aws_iam_role.events.arn &&
      [for p in aws_cloudwatch_event_target.retrain_pipeline.sagemaker_pipeline_target[0].pipeline_parameter_list : "${p.name}=${p.value}"] == ["TriggerReason=drift"]
    )
    error_message = "The rule's one target is the training pipeline with TriggerReason=drift."
  }

  # The roles: one service each; each may start only its pipelines.
  assert {
    condition = (
      jsondecode(aws_iam_role.scheduler.assume_role_policy).Statement[0].Principal.Service == "scheduler.amazonaws.com" &&
      jsondecode(aws_iam_role.events.assume_role_policy).Statement[0].Principal.Service == "events.amazonaws.com" &&
      jsondecode(aws_iam_role_policy.scheduler.policy).Statement[0].Action == ["sagemaker:StartPipelineExecution"] &&
      toset(jsondecode(aws_iam_role_policy.scheduler.policy).Statement[0].Resource) == toset(["arn:aws:sagemaker:ap-southeast-2:123456789012:pipeline/finrisk-train", "arn:aws:sagemaker:ap-southeast-2:123456789012:pipeline/finrisk-monitor"]) &&
      jsondecode(aws_iam_role_policy.events.policy).Statement[0].Action == ["sagemaker:StartPipelineExecution"] &&
      jsondecode(aws_iam_role_policy.events.policy).Statement[0].Resource == "arn:aws:sagemaker:ap-southeast-2:123456789012:pipeline/finrisk-train" &&
      aws_iam_role.scheduler.name == "finrisk-scheduler" && aws_iam_role.events.name == "finrisk-events"
    )
    error_message = "finrisk-scheduler may start both pipelines, finrisk-events only the training pipeline; nothing else."
  }
}

run "the_hourly_monitor_can_be_switched_on" {
  command = plan

  variables {
    monitor_schedule_enabled = true
  }

  assert {
    condition     = aws_scheduler_schedule.hourly_monitor.state == "ENABLED"
    error_message = "monitor_schedule_enabled = true turns the hourly monitor on."
  }
}

run "studio_domain_and_profile_are_read_only_and_leave_nothing_behind" {
  command = apply

  assert {
    condition = (
      length(aws_sagemaker_domain.studio) == 1 &&
      aws_sagemaker_domain.studio[0].domain_name == "finrisk-studio" &&
      aws_sagemaker_domain.studio[0].auth_mode == "IAM" &&
      aws_sagemaker_domain.studio[0].retention_policy[0].home_efs_file_system == "Delete" &&
      aws_sagemaker_domain.studio[0].default_user_settings[0].execution_role == aws_iam_role.studio[0].arn &&
      aws_sagemaker_user_profile.instructor[0].user_profile_name == "instructor" &&
      aws_sagemaker_user_profile.instructor[0].domain_id == aws_sagemaker_domain.studio[0].id &&
      aws_iam_role.studio[0].name == "finrisk-studio"
    )
    error_message = "Domain finrisk-studio (IAM auth, EFS deleted with it), profile instructor, role finrisk-studio."
  }

  # Every action the Studio role has is a read (Describe/List/Get/Search/BatchGet), a log read or an S3 read.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.studio[0].policy).Statement :
      alltrue([for a in tolist(s.Action) : can(regex("^(sagemaker:(Describe|List|Get|Search|BatchGetRecord|CallMlflowAppApi|CreatePresignedMlflowAppUrl)|s3:(GetObject|ListBucket|GetBucketLocation)|logs:(DescribeLogStreams|GetLogEvents))", a))])
    ])
    error_message = "The Studio role only reads."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.studio[0].policy, "s3:Put") && !strcontains(aws_iam_role_policy.studio[0].policy, "sagemaker:Create\"") && !strcontains(aws_iam_role_policy.studio[0].policy, "sagemaker:Delete") && !strcontains(aws_iam_role_policy.studio[0].policy, "iam:")
    error_message = "The Studio role cannot create, delete or write anything."
  }
}

run "studio_can_be_left_out" {
  command = plan

  variables {
    create_studio_domain = false
  }

  assert {
    condition     = length(aws_sagemaker_domain.studio) == 0 && length(aws_sagemaker_user_profile.instructor) == 0 && length(aws_iam_role.studio) == 0 && length(data.aws_vpc.default) == 0
    error_message = "create_studio_domain = false creates no domain, profile, role, and does not even look for the default VPC."
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
      "/finrisk/shared/feature_group",
      "/finrisk/shared/glue_database",
      "/finrisk/shared/labels_table",
      "/finrisk/shared/athena_workgroup",
      "/finrisk/shared/mlflow_app_arn",
      "/finrisk/shared/train_pipeline",
      "/finrisk/shared/monitor_pipeline",
      "/finrisk/shared/model_image_repo",
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
      aws_ssm_parameter.shared["model_package_group"].value == "finrisk-fraud-model" &&
      aws_ssm_parameter.shared["feature_group"].value == "finrisk-transactions" &&
      aws_ssm_parameter.shared["glue_database"].value == "finrisk_ml" &&
      aws_ssm_parameter.shared["labels_table"].value == "labels" &&
      aws_ssm_parameter.shared["athena_workgroup"].value == "finrisk" &&
      aws_ssm_parameter.shared["mlflow_app_arn"].value == aws_sagemaker_mlflow_app.this.arn &&
      aws_ssm_parameter.shared["train_pipeline"].value == "finrisk-train" &&
      aws_ssm_parameter.shared["monitor_pipeline"].value == "finrisk-monitor" &&
      aws_ssm_parameter.shared["model_image_repo"].value == "finrisk-train"
    )
    error_message = "Each parameter must hold the value of the resource it is named after."
  }
}

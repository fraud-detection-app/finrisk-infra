# The home of the MODEL and its DATA, shared by all four environments.
#
# The model is trained ONCE (a SageMaker Pipeline running the training image), registered as a numbered version in
# a Model Registry, approved by a human, and then every environment is put on a version: an endpoint is created or
# updated, and a Parameter Store parameter (/finrisk/<env>/model) says which one. It is never retrained per environment.
# Three things live here:
#
#   1. An S3 bucket for everything ML, one folder (prefix) per kind of thing -- see "the folders" below.
#   2. An execution role for SageMaker: the identity the PIPELINES and their jobs wear (not the app, not you).
#   3. A model package group:           the registry. Each registered model is a numbered version with an approval
#                                       status (PendingManualApproval -> Approved).
#
# The pipelines, the backfill, the registering and the approving are NOT Terraform's job: they happen again and again, at
# different times, with different results (finrisk-ml does them). Terraform builds the place they happen in.

# ---------------------------------------------------------------- the ML bucket
# !! No force_destroy. The model files and the training data are the lineage of what is running in prod ("which data
# !! trained this?"), so `terraform destroy` fails while the bucket is not empty. Empty it by hand (every object
# !! VERSION) and then destroy.
resource "aws_s3_bucket" "ml" {
  bucket           = local.ml_bucket_name
  bucket_namespace = "account-regional"
}

# Versioning: re-uploading data/ or overwriting a model never destroys the old one.
resource "aws_s3_bucket_versioning" "ml" {
  bucket = aws_s3_bucket.ml.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Training data and models are never public. Say so in code.
resource "aws_s3_bucket_public_access_block" "ml" {
  bucket = aws_s3_bucket.ml.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------- the folders of the ML bucket
#   raw/            the PaySim CSV as downloaded (sha256-checked) and the backfill report   KEEP: it is the source of everything
#   data/           training data uploaded by the first version of the pipeline
#   datasets/       one folder per pipeline run: train/validation/test parquet, the monitor's baseline
#   labels/         what really happened (source=history from the backfill, source=feedback from the analysts)   KEEP
#   replay/         days 18-30 as "tomorrow's traffic", written once by the backfill                          KEEP
#   feature-store/  the Feature Store's offline store (parquet written by SageMaker)                           KEEP
#   models/         model.tar.gz of every training job
#   metrics/        evaluation files
#   monitoring/     one folder per monitor run: metrics.json + report.html
#   capture/        the endpoints' Data Capture (what was asked and answered): capture/<env>/...
#   athena/         Athena query results
#   mlflow/         the MLflow App's artifact store
#
# Versioning keeps every old copy forever -- unless told otherwise. These rules delete OLD versions (the ones that are no
# longer "current") after N days, so the bill stays small. The current version of every object stays, and a registered
# model's file is current, so the registry never points at nothing.
#
# The four folders marked KEEP have NO rule on purpose: an old version of the raw CSV, of a label file or of a Feature Store
# file is lineage ("which data trained v3?"), and the Feature Store history cannot be re-bought cheaply (about USD 8.5).
# S3 lets a rule filter on ONE prefix, so there is one rule per folder that may expire.
locals {
  expiring_prefixes = ["data", "datasets", "models", "metrics", "monitoring", "capture", "athena", "mlflow"]
}

resource "aws_s3_bucket_lifecycle_configuration" "ml" {
  bucket = aws_s3_bucket.ml.id

  dynamic "rule" {
    for_each = toset(local.expiring_prefixes)

    content {
      id     = "expire-old-versions-${rule.value}"
      status = "Enabled"

      filter {
        prefix = "${rule.value}/"
      }

      noncurrent_version_expiration {
        noncurrent_days = var.noncurrent_days
      }
    }
  }

  rule {
    id     = "abort-unfinished-uploads"
    status = "Enabled"

    filter {}

    # A big upload that was started and never finished is invisible but billed: clean it up (the 493 MB CSV, the backfill).
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # The rules apply to versioned objects, so versioning must exist first.
  depends_on = [aws_s3_bucket_versioning.ml]
}

# ---------------------------------------------------------------- the SageMaker execution role
# A SageMaker Pipeline runs its steps as THIS role, and every job it starts (Processing, Tuning, Training) wears it too; the
# Feature Store writes its offline files with it; the one-off backfill job wears it. It is the jobs' whole world: whatever is
# not listed below, the code inside them cannot do. (Before week 13b it was only the training job's role.)
resource "aws_iam_role" "sagemaker_exec" {
  name = "${var.project}-sagemaker-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # Only SageMaker working for THIS account may use the role (the "confused deputy" guard).
      Condition = { StringEquals = { "aws:SourceAccount" = local.acct } }
    }]
  })
}

locals {
  arn_glue = "arn:aws:glue:${local.region}:${local.acct}"

  # Folders each kind of access may reach (see "the folders" above). capture/ is READ only here: the endpoints write it with
  # their own role (envs/), and the monitor reads it. data/ is read only: the first upload is the ml-train role's.
  ml_read_prefixes  = ["raw", "data", "datasets", "labels", "replay", "models", "metrics", "monitoring", "capture", "athena", "feature-store", "mlflow"]
  ml_write_prefixes = ["raw", "datasets", "labels", "replay", "models", "metrics", "monitoring", "athena", "feature-store", "mlflow"]
}

resource "aws_iam_role_policy" "sagemaker_exec" {
  name = "${var.project}-sagemaker-exec"
  role = aws_iam_role.sagemaker_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 1. Read the folders. No s3:DeleteObject anywhere: nothing a job does removes data.
        Sid      = "ReadTheMlBucketFolders"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = [for p in local.ml_read_prefixes : "${aws_s3_bucket.ml.arn}/${p}/*"]
      },
      {
        # 2. Write the results: datasets, models (SageMaker packs /opt/ml/model into models/<job>/output/model.tar.gz), metrics,
        #    monitor reports, labels, the replay set, Athena results, Feature Store files, MLflow artifacts.
        Sid      = "WriteTheMlBucketFolders"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = [for p in local.ml_write_prefixes : "${aws_s3_bucket.ml.arn}/${p}/*"]
      },
      {
        # 3. S3 checks the bucket and lists folders before it downloads an input; Athena and the Feature Store ask where the bucket
        #    is and who owns it. Listing shows file NAMES only; reading and writing are limited to the folders above. (The one
        #    wider-than-it-looks line: it cannot be narrowed by prefix without risking a job's start-up.)
        Sid      = "ListMlBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketAcl"]
        Resource = aws_s3_bucket.ml.arn
      },
      {
        # 4. Pull OUR training image from the registry. GetAuthorizationToken has no resource to name (it is the
        #    "log in to ECR" call); the pull actions are limited to the finrisk-train repository.
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "PullTheTrainingImage"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = aws_ecr_repository.this["train"].arn
      },
      {
        # 5. Logs: training and processing jobs write to their own log groups.
        Sid    = "WriteJobLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = [
          "arn:aws:logs:${local.region}:${local.acct}:log-group:/aws/sagemaker/TrainingJobs",
          "arn:aws:logs:${local.region}:${local.acct}:log-group:/aws/sagemaker/TrainingJobs:*",
          "arn:aws:logs:${local.region}:${local.acct}:log-group:/aws/sagemaker/ProcessingJobs",
          "arn:aws:logs:${local.region}:${local.acct}:log-group:/aws/sagemaker/ProcessingJobs:*",
        ]
      },
      {
        # 6. Metrics: SageMaker's own job metrics, and OUR monitor's (namespace FinRisk/Model, dimension Env=prod: the alarms
        #    in envs/ watch them). PutMetricData has no resource to name, so the condition limits it to these namespaces.
        Sid       = "PublishMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = ["/aws/sagemaker/TrainingJobs", "/aws/sagemaker/ProcessingJobs", "FinRisk/Model"] } }
      },
      {
        # 7. The pipelines' steps: Processing jobs, the tuning job and the training jobs it starts.
        #    BROAD ON PURPOSE (job/*): SageMaker Pipelines names the jobs it creates itself
        #    (processing-job/pipelines-<execution id>-BuildDataset-<random>; the tuning job and its trials get generated names
        #    too), so no name prefix can be written here. The first live run (20 Oct 2026) failed on exactly this: AddTags on
        #    processing-job/pipelines-... was denied while the policy said finrisk-*. The guards are elsewhere: only SageMaker
        #    can assume this role (trust policy), only finrisk-ml's train role may start the two pipelines, and these actions
        #    only run, describe, stop and tag jobs -- they cannot read any data this role is not already given above.
        Sid    = "RunTheJobsThePipelinesStart"
        Effect = "Allow"
        Action = [
          "sagemaker:CreateProcessingJob", "sagemaker:DescribeProcessingJob", "sagemaker:StopProcessingJob",
          "sagemaker:CreateTrainingJob", "sagemaker:DescribeTrainingJob", "sagemaker:StopTrainingJob",
          "sagemaker:CreateHyperParameterTuningJob", "sagemaker:DescribeHyperParameterTuningJob", "sagemaker:StopHyperParameterTuningJob",
          "sagemaker:ListTrainingJobsForHyperParameterTuningJob", "sagemaker:AddTags", "sagemaker:ListTags",
        ]
        Resource = [
          "${local.arn_sm}:processing-job/*",
          "${local.arn_sm}:training-job/*",
          "${local.arn_sm}:hyper-parameter-tuning-job/*",
        ]
      },
      {
        # 8. Register a version in the ONE model group (it starts PendingManualApproval; approving is another role's job).
        #    CreateModelPackageGroup: the pipeline's RegisterModel step calls it first, every time, even though Terraform made
        #    the group (it treats "already exists" as fine). Without it the first live Register step was refused
        #    (20 Oct 2026). Scoped to this one group's ARN, so it can only "create" the group that already exists.
        Sid    = "RegisterAndReadModelVersions"
        Effect = "Allow"
        Action = ["sagemaker:CreateModelPackageGroup", "sagemaker:CreateModelPackage", "sagemaker:DescribeModelPackage", "sagemaker:ListModelPackages", "sagemaker:DescribeModelPackageGroup", "sagemaker:AddTags"]
        Resource = [
          aws_sagemaker_model_package_group.model.arn,
          "${local.arn_sm}:model-package/${aws_sagemaker_model_package_group.model.model_package_group_name}/*",
        ]
      },
      {
        # 9. A tuning step hands this same role to the jobs it starts: PassRole on itself, to SageMaker only.
        Sid       = "PassItselfToTheJobsItStarts"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = aws_iam_role.sagemaker_exec.arn
        Condition = { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } }
      },
      {
        # 10. The Feature Store: write records (the backfill), read the group's definition. The offline files land in feature-store/.
        Sid      = "WriteRecordsToTheFeatureGroup"
        Effect   = "Allow"
        Action   = ["sagemaker:BatchWriteRecord", "sagemaker:PutRecord", "sagemaker:DescribeFeatureGroup"]
        Resource = local.feature_group_arn
      },
      {
        # 11. The Glue catalog behind Athena: read the finrisk_ml database; the Feature Store (which wears this role) creates and
        #     keeps the `transactions` table in it. Not the labels table: only Terraform changes that one.
        Sid    = "ReadTheDataCatalog"
        Effect = "Allow"
        Action = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition"]
        Resource = [
          "${local.arn_glue}:catalog",
          "${local.arn_glue}:database/${local.glue_database}",
          "${local.arn_glue}:table/${local.glue_database}/*",
        ]
      },
      {
        Sid      = "KeepTheFeatureStoreTable"
        Effect   = "Allow"
        Action   = ["glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable"]
        Resource = ["${local.arn_glue}:catalog", "${local.arn_glue}:database/${local.glue_database}", "${local.arn_glue}:table/${local.glue_database}/${local.features_table}"]
      },
      {
        # 12. Athena: run queries in the workgroup finrisk only (its results go to athena/, enforced by the workgroup).
        Sid      = "QueryInTheFinriskWorkgroup"
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:StopQueryExecution", "athena:GetWorkGroup"]
        Resource = "arn:aws:athena:${local.region}:${local.acct}:workgroup/${local.workgroup}"
      },
      {
        # 13. Names that are the same everywhere, and "which model does prod serve" (the champion the gate compares with).
        Sid      = "ReadSharedNamesAndTheProdModelPointer"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = ["arn:aws:ssm:${local.region}:${local.acct}:parameter/${var.project}/shared/*", "arn:aws:ssm:${local.region}:${local.acct}:parameter/${var.project}/prod/model"]
      },
      {
        # 14. MLflow: log runs. The action prefix for an MLflow APP is `sagemaker:` (the `sagemaker-mlflow:` prefix belongs to the
        #     older tracking SERVERS); its ARN ends in an id AWS chooses, so the only name available before it exists is the pattern.
        Sid      = "LogToTheMlflowApp"
        Effect   = "Allow"
        Action   = ["sagemaker:CallMlflowAppApi", "sagemaker:DescribeMlflowApp"]
        Resource = "${local.arn_sm}:mlflow-app/*"
      },
    ]
  })
}

# ---------------------------------------------------------------- the Model Registry
# One group = one model, many versions. finrisk-ml registers version 1, 2, 3 ... each starting as
# PendingManualApproval. The group itself is just a name and a description, so destroying it is a decision about the
# REGISTRY (the model files stay in the bucket).
resource "aws_sagemaker_model_package_group" "model" {
  model_package_group_name        = "${var.project}-fraud-model"
  model_package_group_description = "Fraud-risk models for ${var.project}: one numbered version per training run, each approved by a person before pre-prod and prod may use it."
}

# The home of the MODEL, shared by all four environments.
#
# The model is trained ONCE (a SageMaker training job running the training image), registered as a numbered version in
# a Model Registry, approved by a human, and then every environment is pointed at a version through a Parameter Store
# parameter (/finrisk/<env>/model). It is never retrained per environment. Three things live here:
#
#   1. An S3 bucket for the ML files:   data/  (training data)   models/  (model.tar.gz)   metrics/
#   2. An execution role for SageMaker: the identity the TRAINING JOB wears (not the app, not you).
#   3. A model package group:           the registry. Each registered model is a numbered version with an approval
#                                       status (PendingManualApproval -> Approved).
#
# The training job, the registering and the approving are NOT Terraform's job: they happen again and again, at
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

# Versioning keeps every old copy forever -- unless told otherwise. This rule deletes OLD versions (the ones that are
# no longer "current") after N days, so the bill stays small. The current version of every object stays, and a
# registered model's file is current, so the registry never points at nothing.
resource "aws_s3_bucket_lifecycle_configuration" "ml" {
  bucket = aws_s3_bucket.ml.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_days
    }

    # A big upload that was started and never finished is invisible but billed: clean it up.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # The rule applies to versioned objects, so versioning must exist first.
  depends_on = [aws_s3_bucket_versioning.ml]
}

# ---------------------------------------------------------------- the SageMaker execution role
# A SageMaker training job runs YOUR container on SageMaker's machine, wearing THIS role. It is the job's whole world:
# whatever is not listed below, the training code cannot do.
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

resource "aws_iam_role_policy" "sagemaker_exec" {
  name = "${var.project}-sagemaker-exec"
  role = aws_iam_role.sagemaker_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 1. Read the training data -- and nothing else in the bucket.
        Sid      = "ReadTrainingData"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.ml.arn}/data/*"
      },
      {
        # 2. Write the results: the model (SageMaker packs /opt/ml/model into models/<job>/output/model.tar.gz) and
        #    the metrics file the training script uploads to metrics/<job>/.
        Sid      = "WriteModelsAndMetrics"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = ["${aws_s3_bucket.ml.arn}/models/*", "${aws_s3_bucket.ml.arn}/metrics/*"]
      },
      {
        # 3. S3 checks the bucket and lists the data/ folder before it downloads the input. Listing shows file NAMES
        #    only; reading and writing are limited to the prefixes above. (The one wider-than-it-looks line: it cannot
        #    be narrowed by prefix without risking the job's start-up.)
        Sid      = "ListMlBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
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
        # 5. Logs: a training job writes to its own log group, /aws/sagemaker/TrainingJobs.
        Sid    = "WriteTrainingLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = [
          "arn:aws:logs:${local.region}:${local.acct}:log-group:/aws/sagemaker/TrainingJobs",
          "arn:aws:logs:${local.region}:${local.acct}:log-group:/aws/sagemaker/TrainingJobs:*",
        ]
      },
      {
        # 6. Metrics: the "pr_auc=0.93" lines the script prints become CloudWatch metrics. PutMetricData has no
        #    resource to name, so the condition limits it to SageMaker's own namespace.
        Sid       = "PublishTrainingMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "/aws/sagemaker/TrainingJobs" } }
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

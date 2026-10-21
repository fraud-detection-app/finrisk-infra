# bootstrap -- what must exist BEFORE any pipeline can run. Applied ONCE, by hand, by an admin.
#
#   1. The S3 bucket that holds Terraform's state for shared/ and envs/ (and finrisk-app's service stack).
#   2. The GitHub identity provider (oidc.tf) and every IAM role the four repositories use (roles_*.tf).
#
# Why by hand? A pipeline needs a role to run, and the role has to be made by somebody. This folder is that
# somebody's work, done once. Its own state stays on the instructor's laptop (terraform.tfstate, git-ignored),
# because it cannot live in a bucket it has not created yet. Everything else (shared/, envs/) is applied
# by GitHub Actions from then on. README.md, "Doing it for the first time" (steps 1-3) shows the commands.
#
# Also once per account, before the first ECS Express Mode service (pre-prod, prod): three service-linked roles.
# AWS creates them on first use, but a brand-new account's first Express service does not wait for them.
# They are free and stay. "has been taken in this account" means they exist already, which is fine.
#
#   aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com
#   aws iam create-service-linked-role --aws-service-name elasticloadbalancing.amazonaws.com
#   aws iam create-service-linked-role --aws-service-name ecs.application-autoscaling.amazonaws.com

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  acct   = data.aws_caller_identity.current.account_id
  region = data.aws_region.current.region

  # The four environments: the same words in every repository, workflow and tfvars file.
  environments = ["dev", "sit", "pre-prod", "prod"]

  # ---- names. shared/ and envs/ build resources with EXACTLY these names (their tests check the same strings),
  # ---- so a role here can name the resource it may touch before that resource exists.
  # S3's "account regional namespace": <prefix>-<12-digit account id>-<region>-an. Only this account can
  # create names ending in its own suffix -- no "BucketAlreadyExists" surprises.
  state_bucket        = "${var.project}-tfstate-${local.acct}-${local.region}-an"
  ml_bucket           = "${var.project}-ml-${local.acct}-${local.region}-an"
  kb_bucket           = "${var.project}-kb-${local.acct}-${local.region}-an"
  env_bucket          = { for e in local.environments : e => "${var.project}-${e}-${local.acct}-${local.region}-an" }
  ecr_app             = "${var.project}-app"
  ecr_train           = "${var.project}-train"
  ecr_host            = "${local.acct}.dkr.ecr.${local.region}.amazonaws.com"
  sagemaker_role_name = "${var.project}-sagemaker-exec"
  model_group         = "${var.project}-fraud-model"

  # ---- the SageMaker lifecycle (week 13b): names shared/ and envs/ create, spelled once here so the roles can name them.
  train_pipeline   = "${var.project}-train"        # SageMaker Pipeline: dataset -> tune -> evaluate -> gate -> register
  monitor_pipeline = "${var.project}-monitor"      # SageMaker Pipeline: one Processing step, our own drift/quality monitor
  feature_group    = "${var.project}-transactions" # Feature Store (offline only)
  glue_database    = "${var.project}_ml"           # Glue / Athena database (underscore: Athena names do not allow '-')
  athena_workgroup = var.project                   # Athena workgroup "finrisk"
  mlflow_app_name  = "${var.project}-mlflow"
  # Roles shared/ creates besides the SageMaker execution role. apply-shared may write exactly these names.
  mlflow_role_name    = "${var.project}-mlflow"    # what the MLflow App wears to reach its artifact store
  scheduler_role_name = "${var.project}-scheduler" # what EventBridge Scheduler wears to start a pipeline
  events_role_name    = "${var.project}-events"    # what the EventBridge rule wears to start a pipeline
  studio_role_name    = "${var.project}-studio"    # what SageMaker Studio wears (read-only)
}

# ---------------------------------------------------------------- Terraform state bucket
# !! This bucket holds the state of EVERY stack, prod included. Destroying it loses Terraform's memory of what
# !! exists: the resources keep running (and billing) but Terraform can no longer manage them. So there is
# !! deliberately no force_destroy: `terraform destroy` here fails while the bucket is not empty. Tear it down
# !! LAST, after every other stack is destroyed, and empty it by hand first -- it is versioned, so "empty" means
# !! every object VERSION (the console's Empty button does that; `aws s3 rm --recursive` does not).
resource "aws_s3_bucket" "state" {
  bucket           = local.state_bucket
  bucket_namespace = "account-regional"
}

# Every state write keeps the old version: a corrupted or deleted state file can be restored.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# State can contain secrets. Say "never public" in code, so nobody switches it off unnoticed.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning keeps every old copy forever -- unless told otherwise. This rule removes OLD versions after N days.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_noncurrent_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# envs/ -- the foundations of ONE environment: its bucket, its log group, the identity the running app wears, and the
# names other pipelines read from Parameter Store. The same code makes dev, sit, pre-prod and prod; only the tfvars
# file and the workspace differ.
#
# Who runs this: the pipeline. .github/workflows/infra-deliver.yml does exactly what scripts/tf.sh does (init with the
# bucket from a GitHub secret, workspace select, plan -out, apply tfplan), one job per environment, in order.
#
#   terraform init -backend-config=...                 connect to the shared state bucket
#   terraform workspace select -or-create dev          one workspace = one environment = one state file
#   terraform plan  -var-file=dev.tfvars -out=tfplan
#   terraform apply tfplan
#
# What is NOT here: the compute (Lambda or ECS Express service) and the image. finrisk-app deploys those, on its own
# pipeline, into the roles and the log group created here. The model and the index are not here either: only their
# POINTERS are (ssm.tf), and finrisk-ml / finrisk-knowledge own what the pointers say.
#
# The model is served from a SageMaker ENDPOINT (week 13b): finrisk-ml creates it (finrisk-<env>-fraud); this stack creates what
# it stands on -- the role the endpoint wears, the permission for the app to call it, and the alarms that watch it.
#
# Files: main.tf (guard, names, bucket, logs) - iam.tf (the app's runtime role) - endpoint.tf (the endpoint's role) -
#        alarms.tf (the endpoint guardrails; in prod also the model alarms) - ecs.tf (pre-prod and prod: the two roles ECS
#        Express Mode needs) - ssm.tf (the parameters) - <env>.tfvars

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# The names finrisk-infra/shared published. If shared/ has not been applied, the plan stops right here, in words.
data "aws_ssm_parameter" "ml_bucket" {
  name = "/${var.project}/shared/ml_bucket"
}

data "aws_ssm_parameter" "kb_bucket" {
  name = "/${var.project}/shared/kb_bucket"
}

locals {
  name = "${var.project}-${var.env}"

  # S3's "account regional namespace": <prefix>-<12-digit account id>-<region>-an.
  bucket_name = "${local.name}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}-an"

  # insecure_value: these are bucket names, not secrets, so the plan can show the policies that use them.
  ml_bucket = data.aws_ssm_parameter.ml_bucket.insecure_value
  kb_bucket = data.aws_ssm_parameter.kb_bucket.insecure_value

  # The endpoint of this environment, and what kind it is. dev and sit: SERVERLESS (scales to zero, no Data Capture, no blue/green).
  # pre-prod and prod: REAL-TIME with Data Capture and blue/green deployment guarded by alarms. The kind decides which of the
  # things below exist: capture/ write permission and the two guardrail alarms.
  endpoint_name     = "${local.name}-fraud"
  realtime_endpoint = contains(["pre-prod", "prod"], var.env)
  is_prod           = var.env == "prod"

  arn_sm = "arn:aws:sagemaker:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"
}

# ---------------------------------------------------------------- the safety catch
# `-var-file=prod.tfvars` while the workspace is `dev` would write prod's resources into dev's state file -- and the
# next dev apply could then delete them. This stops that.
#
# Why a precondition and not a `check` block: a failed `check` only prints a warning and the apply carries on. A
# failed `precondition` is an ERROR during plan, so nothing is created or changed.
resource "terraform_data" "workspace_matches_env" {
  lifecycle {
    precondition {
      condition     = terraform.workspace == var.env
      error_message = "Workspace '${terraform.workspace}' does not match env '${var.env}'. Run `terraform workspace select -or-create ${var.env}` (or pass the tfvars file that belongs to this workspace)."
    }
  }
}

# ---------------------------------------------------------------- the environment's data bucket
resource "aws_s3_bucket" "env" {
  bucket           = local.bucket_name
  bucket_namespace = "account-regional"

  # dev and sit hold only demo data, so `terraform destroy` may empty them.
  # pre-prod and prod must be emptied deliberately -- never as a side effect of destroy.
  force_destroy = contains(["dev", "sit"], var.env)

  depends_on = [terraform_data.workspace_matches_env]
}

# "Disabled" is only valid when the bucket is new; pre-prod and prod turn it on (a delete can be undone).
resource "aws_s3_bucket_versioning" "env" {
  bucket = aws_s3_bucket.env.id

  versioning_configuration {
    status = var.bucket_versioning ? "Enabled" : "Disabled"
  }
}

resource "aws_s3_bucket_public_access_block" "env" {
  bucket = aws_s3_bucket.env.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------- logs
# Created BEFORE the compute, so Terraform owns it: retention is set, and destroy removes it too (left to Lambda or
# ECS, the log group would never expire and would outlive the app).
resource "aws_cloudwatch_log_group" "app" {
  name              = "/app/${local.name}"
  retention_in_days = var.log_retention_days

  depends_on = [terraform_data.workspace_matches_env]
}

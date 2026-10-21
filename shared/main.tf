# shared/ -- what all four environments (and the model and knowledge pipelines) share. Applied by the PIPELINE
# (.github/workflows/infra-deliver.yml, job apply-shared, Environment infra-shared), never from a laptop.
#
#   ecr.tf  two container registries: finrisk-app (the service image) and finrisk-train (the training image)
#   ml.tf          the ML bucket, the SageMaker execution role (the pipelines' role too), the Model Registry group
#   features.tf    the data platform: Glue database finrisk_ml + labels table, the Feature Store group finrisk-transactions,
#                  the Athena workgroup finrisk
#   mlflow.tf      the serverless MLflow App finrisk-mlflow and the role it wears
#   automation.tf  EventBridge Scheduler (weekly retrain, hourly monitor) and the EventBridge rule that retrains on drift
#   studio.tf      the SageMaker Studio domain and user profile (optional, on by default)
#   kb.tf          the knowledge-base bucket (the RAG indexes)
#   ssm.tf         /finrisk/shared/*: the names above, published in Parameter Store so other repositories can find them
#
# Why Parameter Store? finrisk-app, finrisk-ml and finrisk-knowledge are separate repositories. They cannot read this
# stack's Terraform outputs, but they can read a parameter. The names are a contract: bootstrap/ builds the roles that
# may touch these resources by the same names (both stacks' tests assert the same strings).

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  acct   = data.aws_caller_identity.current.account_id
  region = data.aws_region.current.region

  # S3's "account regional namespace": <prefix>-<12-digit account id>-<region>-an.
  # Only this account can create names ending in its own suffix -- no "BucketAlreadyExists" surprises.
  ml_bucket_name = "${var.project}-ml-${local.acct}-${local.region}-an"
  kb_bucket_name = "${var.project}-kb-${local.acct}-${local.region}-an"

  # ---- names (week 13b). bootstrap/ builds the roles that may touch these things by the same strings (both stacks' tests
  # ---- assert them). The two pipelines are made by finrisk-ml, not by Terraform: only their NAMES are known here.
  train_pipeline   = "${var.project}-train"
  monitor_pipeline = "${var.project}-monitor"
  feature_group    = "${var.project}-transactions"
  glue_database    = "${var.project}_ml" # Athena/Glue names allow '_' but not '-'
  labels_table     = "labels"
  features_table   = "transactions" # the Feature Store creates this table in the database above
  workgroup        = var.project
  mlflow_app       = "${var.project}-mlflow"
  schedule_group   = var.project

  # ARNs built from names (not read from the resources) so the execution role's policy and the resources that use the
  # role can never wait for each other.
  arn_sm               = "arn:aws:sagemaker:${local.region}:${local.acct}"
  train_pipeline_arn   = "${local.arn_sm}:pipeline/${local.train_pipeline}"
  monitor_pipeline_arn = "${local.arn_sm}:pipeline/${local.monitor_pipeline}"
  feature_group_arn    = "${local.arn_sm}:feature-group/${local.feature_group}"
}

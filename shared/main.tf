# shared/ -- what all four environments (and the model and knowledge pipelines) share. Applied by the PIPELINE
# (.github/workflows/infra-deliver.yml, job apply-shared, Environment infra-shared), never from a laptop.
#
#   ecr.tf  two container registries: finrisk-app (the service image) and finrisk-train (the training image)
#   ml.tf   the ML bucket, the SageMaker execution role, the Model Registry group
#   kb.tf   the knowledge-base bucket (the RAG indexes)
#   ssm.tf  /finrisk/shared/*: the names above, published in Parameter Store so other repositories can find them
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
}

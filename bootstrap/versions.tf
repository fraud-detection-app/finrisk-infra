# Which Terraform and which provider this folder needs. `terraform init` reads this first.
#
# Terraform 1.15+  : same version the pipelines use (hashicorp/setup-terraform in the workflows).
# AWS provider 6.68+: account-regional bucket names (6.37+) and `aws login` credentials (6.23+).
# The exact provider version is recorded in .terraform.lock.hcl -- commit that file.
#
# There is NO backend block: bootstrap keeps LOCAL state (terraform.tfstate next to these files), because it
# creates the bucket that every other stack keeps its state in. See the README, "Doing it for the first time".

terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
}

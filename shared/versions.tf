# Which Terraform and which provider this folder needs. `terraform init` reads this first.
#
# Terraform 1.15+  : its S3 backend understands `aws login` credentials and keeps its lock in S3 (use_lockfile).
# AWS provider 6.68+: account-regional bucket names (6.37+) and `aws login` credentials (6.23+).
# The exact provider version is recorded in .terraform.lock.hcl -- commit that file.

terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
}

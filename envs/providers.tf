# The AWS provider: which Region, and tags every resource gets automatically.
# Environment = the workspace-matched env name (main.tf refuses to run when they differ).

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
      Course      = "financial-risk-assistant"
    }
  }
}

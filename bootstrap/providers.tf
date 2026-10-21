# The AWS provider: which Region, and tags every resource gets automatically.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = "bootstrap"
      ManagedBy   = "terraform"
      Course      = "financial-risk-assistant"
    }
  }
}

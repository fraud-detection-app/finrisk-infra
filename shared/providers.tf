# The AWS provider: which Region, and tags every resource gets automatically.
# "shared" is not an environment -- these resources serve all four of them.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = "shared"
      ManagedBy   = "terraform"
      Course      = "financial-risk-assistant"
    }
  }
}

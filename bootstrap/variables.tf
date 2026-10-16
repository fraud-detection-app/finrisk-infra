# The inputs. Every one has a default, so `terraform apply` needs no flags.

variable "project" {
  description = "Short project name; the first part of every resource name."
  type        = string
  default     = "finrisk"
}

variable "aws_region" {
  description = "Where everything lives. Terraform does NOT follow the console's Region menu."
  type        = string
  default     = "ap-southeast-2" # Sydney
}

variable "github_org" {
  description = "The GitHub organisation that owns the four repositories, spelled exactly as GitHub spells it: the token's `sub` claim is case-sensitive."
  type        = string
  default     = "fraud-detection-app"

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$", var.github_org))
    error_message = "github_org must be a GitHub user or organisation name (letters, digits and hyphens; no '/', no wildcards)."
  }
}

variable "repos" {
  description = "The four repositories (names only, not owner/name). Only these can assume the roles."
  type        = map(string)
  default = {
    infra     = "finrisk-infra"
    app       = "finrisk-app"
    ml        = "finrisk-ml"
    knowledge = "finrisk-knowledge"
  }

  validation {
    condition     = toset(keys(var.repos)) == toset(["infra", "app", "ml", "knowledge"])
    error_message = "repos needs exactly the keys infra, app, ml and knowledge."
  }

  validation {
    condition     = alltrue([for name in values(var.repos) : can(regex("^[A-Za-z0-9._-]+$", name))])
    error_message = "A repository name may hold letters, digits, '.', '_' and '-' only (no '/', no wildcards)."
  }
}

variable "create_oidc_provider" {
  description = "Create the GitHub identity provider. There can be only ONE per AWS account: set false if another project (for example week 13a's practice repo) already created it. The roles then trust the existing one."
  type        = bool
  default     = true
}

variable "state_noncurrent_days" {
  description = "How long S3 keeps OLD versions of state files before removing them."
  type        = number
  default     = 90
}

variable "embedding_model_id" {
  description = "The Bedrock embedding model the knowledge pipeline may call (foundation model, this Region)."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

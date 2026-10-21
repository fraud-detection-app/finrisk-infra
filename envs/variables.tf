# The inputs. <env>.tfvars sets the per-environment ones:
#   terraform apply -var-file=dev.tfvars        (in the workspace dev)

variable "project" {
  description = "Short project name; the first part of every resource name."
  type        = string
  default     = "finrisk"
}

variable "env" {
  description = "Which environment this copy is. Must match the Terraform workspace."
  type        = string

  validation {
    condition     = contains(["dev", "sit", "pre-prod", "prod"], var.env)
    error_message = "env must be dev, sit, pre-prod or prod."
  }
}

variable "compute" {
  description = "What will run the container (finrisk-app decides the rest): lambda (scales to zero) or ecs (ECS Express Mode, always warm). Here it only decides whether the two ECS roles exist."
  type        = string

  validation {
    condition     = contains(["lambda", "ecs"], var.compute)
    error_message = "compute must be lambda or ecs."
  }
}

variable "aws_region" {
  description = "Where everything lives. Terraform does NOT follow the console's Region menu."
  type        = string
  default     = "ap-southeast-2" # Sydney
}

variable "log_retention_days" {
  description = "How long CloudWatch keeps the logs: 7 in dev up to 90 in prod."
  type        = number
  default     = 7
}

variable "bucket_versioning" {
  description = "Keep every version of every object in the environment's bucket (pre-prod and prod)."
  type        = bool
  default     = false
}

variable "bedrock_chat_model_id" {
  description = "The Bedrock chat model the app may call through its role. No API key anywhere."
  type        = string
  default     = "deepseek.v3.2" # ON_DEMAND in ap-southeast-2
}

variable "bedrock_embedding_model_id" {
  description = "The Bedrock embedding model the app uses to embed a question (when the index was built with Titan)."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "pointer_seed" {
  description = "The value a model/index pointer gets WHEN IT IS CREATED: \"nothing promoted yet\". It is never applied again (ignore_changes), so changing it does nothing to an existing pointer; the pipelines own the pointers."
  type        = string
  default     = "{\"version\": null}"
}

# ---- the thresholds of the three PROD model alarms (alarms.tf). Variables, so a pull request can change them and the plan shows it.
variable "drift_psi_threshold" {
  description = "finrisk-prod-model-drift: the largest per-feature PSI or the score PSI at or above this is a significant shift (the industry band: < 0.1 stable, 0.1-0.25 moderate, >= 0.25 significant)."
  type        = number
  default     = 0.25
}

variable "fraud_rate_ratio_threshold" {
  description = "finrisk-prod-model-prior-shift: live fraud rate / the training split's fraud rate at or above this means fraud is that many times as common as the model was trained for."
  type        = number
  default     = 5
}

variable "live_pr_auc_floor" {
  description = "finrisk-prod-model-quality: live PR-AUC below this (once there are enough labelled rows) is a quality failure."
  type        = number
  default     = 0.70
}

variable "min_labelled_rows" {
  description = "finrisk-prod-model-quality only judges the live PR-AUC when at least this many live rows have a label yet (a handful of labels says nothing)."
  type        = number
  default     = 500
}

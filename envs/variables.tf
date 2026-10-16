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

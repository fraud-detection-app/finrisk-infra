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

variable "keep_images" {
  description = "How many images each registry keeps. Older ones are deleted automatically."
  type        = number
  default     = 10
}

variable "noncurrent_days" {
  description = "How long S3 keeps OLD versions of ML and knowledge-base files (overwritten or deleted objects) before removing them."
  type        = number
  default     = 30
}

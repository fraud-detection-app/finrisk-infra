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

variable "create_studio_domain" {
  description = "Create the SageMaker Studio domain finrisk-studio (+ the user profile `instructor`) in the DEFAULT VPC. It is how the class SEES the pipeline graph, the registry, model cards and endpoints. It needs the account's default VPC; set false if there is none (or if you do not want Studio). Nothing runs in it and only the EFS bytes cost money."
  type        = bool
  default     = true
}

variable "monitor_schedule_enabled" {
  description = "Turn the hourly drift/quality monitor (EventBridge Scheduler finrisk-hourly-monitor) ON. It is OFF by default: each run is a small Processing job, and in class the monitor is started by hand (monitor.yml) so the students see it happen."
  type        = bool
  default     = false
}

variable "weekly_retrain_enabled" {
  description = "Keep the weekly retraining schedule (finrisk-weekly-retrain, Monday 02:00 Sydney) ENABLED. Each run costs about USD 0.30."
  type        = bool
  default     = true
}

variable "athena_bytes_scanned_cutoff" {
  description = "A query that would scan more than this many bytes is stopped (Athena bills by data scanned). 10 GB; the full feature history is a few GB."
  type        = number
  default     = 10737418240
}

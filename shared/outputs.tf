# Outputs print after `terraform apply` -- and any time with `terraform output`.

output "ecr_app_url" {
  description = "Where the service image is pushed. Deploy as <this>@sha256:<digest>."
  value       = aws_ecr_repository.this["app"].repository_url
}

output "ecr_train_url" {
  description = "Where the training image is pushed."
  value       = aws_ecr_repository.this["train"].repository_url
}

output "ml_bucket" {
  description = "The ML bucket (raw/, data/, datasets/, labels/, replay/, models/, metrics/, monitoring/, capture/, athena/, feature-store/, mlflow/)."
  value       = aws_s3_bucket.ml.bucket
}

output "kb_bucket" {
  description = "The knowledge-base bucket (indexes/<version>/)."
  value       = aws_s3_bucket.kb.bucket
}

output "sagemaker_role_arn" {
  description = "The role a training job wears."
  value       = aws_iam_role.sagemaker_exec.arn
}

output "model_package_group" {
  description = "The Model Registry group."
  value       = aws_sagemaker_model_package_group.model.model_package_group_name
}

output "parameters" {
  description = "The parameters published for the other pipelines."
  value       = sort([for p in aws_ssm_parameter.shared : p.name])
}

output "feature_group" {
  description = "The Feature Store group (offline only)."
  value       = aws_sagemaker_feature_group.transactions.feature_group_name
}

output "glue_database" {
  description = "The Glue/Athena database (tables: labels, and transactions made by the Feature Store)."
  value       = aws_glue_catalog_database.ml.name
}

output "athena_workgroup" {
  description = "The Athena workgroup for the model queries."
  value       = aws_athena_workgroup.finrisk.name
}

output "mlflow_app_arn" {
  description = "The serverless MLflow App (tracking URI)."
  value       = aws_sagemaker_mlflow_app.this.arn
}

output "schedules" {
  description = "The EventBridge Scheduler schedules and their state, and the on-drift rule."
  value = {
    weekly_retrain = aws_scheduler_schedule.weekly_retrain.state
    hourly_monitor = aws_scheduler_schedule.hourly_monitor.state
    retrain_rule   = aws_cloudwatch_event_rule.retrain_on_drift.name
  }
}

output "studio_domain_id" {
  description = "The Studio domain id (empty when create_studio_domain = false)."
  value       = try(aws_sagemaker_domain.studio[0].id, "")
}

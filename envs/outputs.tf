# Outputs print after `terraform apply` -- and any time with `terraform output`.

output "env" {
  description = "The environment name."
  value       = var.env
}

output "compute" {
  description = "lambda or ecs."
  value       = var.compute
}

output "bucket_name" {
  description = "The environment's data bucket, including the account-regional suffix."
  value       = aws_s3_bucket.env.bucket
}

output "log_group" {
  description = "Where the app's logs go (CloudWatch)."
  value       = aws_cloudwatch_log_group.app.name
}

output "runtime_role_arn" {
  description = "The identity the running app wears."
  value       = aws_iam_role.runtime.arn
}

output "parameters" {
  description = "Every parameter this stack manages for the environment (the two pointers included)."
  value       = sort(concat([for p in aws_ssm_parameter.env : p.name], [aws_ssm_parameter.model_pointer.name, aws_ssm_parameter.index_pointer.name]))
}

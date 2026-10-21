# /finrisk/shared/*: the names the other repositories need, published in Parameter Store.
#
# Plain `String` parameters: none of these is a secret (a bucket name, a registry address, a role ARN). The
# SSM names are a contract with finrisk-app, finrisk-ml and finrisk-knowledge -- do not rename one without them.

locals {
  shared_parameters = {
    ecr_app_url         = aws_ecr_repository.this["app"].repository_url
    ecr_train_url       = aws_ecr_repository.this["train"].repository_url
    ml_bucket           = aws_s3_bucket.ml.bucket
    kb_bucket           = aws_s3_bucket.kb.bucket
    sagemaker_role_arn  = aws_iam_role.sagemaker_exec.arn
    model_package_group = aws_sagemaker_model_package_group.model.model_package_group_name

    # Week 13b: the data platform, the pipelines and MLflow. finrisk-ml reads these instead of hard-coding names.
    feature_group    = aws_sagemaker_feature_group.transactions.feature_group_name
    glue_database    = aws_glue_catalog_database.ml.name
    labels_table     = aws_glue_catalog_table.labels.name # the Feature Store's own table is `transactions` (same database)
    athena_workgroup = aws_athena_workgroup.finrisk.name
    mlflow_app_arn   = aws_sagemaker_mlflow_app.this.arn
    train_pipeline   = local.train_pipeline # the pipelines are made by finrisk-ml; only their names are fixed here
    monitor_pipeline = local.monitor_pipeline
    model_image_repo = aws_ecr_repository.this["train"].name # the one image that trains and serves (name, not URL: ecr_train_url is the URL)
  }
}

resource "aws_ssm_parameter" "shared" {
  for_each = local.shared_parameters

  name        = "/${var.project}/shared/${each.key}"
  type        = "String"
  value       = each.value
  description = "Published by finrisk-infra/shared. Read by the other pipelines."
}

# MLflow: every training run, evaluation and monitor run is logged here and compared in one UI (week 13b).
#
# This is the SERVERLESS MLflow App of SageMaker AI: nothing to size, nothing running when idle, no extra charge. One app per
# account. Training, evaluation and monitoring log to it by its ARN (the `sagemaker-mlflow` plugin reads the tracking URI);
# the ARN is published as /finrisk/shared/mlflow_app_arn. Students open the UI with `aws sagemaker create-presigned-mlflow-app-url`
# (finrisk-ml: `mlops.py mlflow-url`).
#
# Two roles are involved, and they are different things:
#   finrisk-mlflow          what the APP wears to write its artifacts (below): only the mlflow/ folder of the ML bucket
#   finrisk-sagemaker-exec  what the JOBS wear to call the app (sagemaker:CallMlflowAppApi, in ml.tf)

resource "aws_iam_role" "mlflow" {
  name = "${var.project}-mlflow"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.acct } }
    }]
  })
}

resource "aws_iam_role_policy" "mlflow" {
  name = "${var.project}-mlflow"
  role = aws_iam_role.mlflow.id

  # AWS's example gives the app s3:Get*/Put*/List* on "*" plus model-registry actions. We narrow it to ONE folder and leave
  # the registry out: automatic registration is off, because OUR registry (the Model Registry group, finrisk-fraud-model) is
  # the system of record and a model enters it only through the pipeline's gate.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ArtifactsInTheMlflowFolder"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.ml.arn}/mlflow/*"
      },
      {
        Sid       = "ListTheMlflowFolder"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.ml.arn
        Condition = { StringLike = { "s3:prefix" = ["mlflow/*", "mlflow/"] } }
      },
      {
        # (No prefix condition here: GetBucketLocation has no prefix to compare.)
        Sid      = "FindTheBucketRegion"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = aws_s3_bucket.ml.arn
      },
    ]
  })
}

resource "aws_sagemaker_mlflow_app" "this" {
  name               = local.mlflow_app
  artifact_store_uri = "s3://${aws_s3_bucket.ml.bucket}/mlflow/"
  role_arn           = aws_iam_role.mlflow.arn

  # Our registry is the system of record (see above): MLflow does not register models behind its back.
  model_registration_mode = "AutoModelRegistrationDisabled"

  depends_on = [aws_iam_role_policy.mlflow]
}

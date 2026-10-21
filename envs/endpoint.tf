# The role this environment's SageMaker ENDPOINT wears.
#
# finrisk-ml creates the endpoint (finrisk-<env>-fraud) and tells SageMaker "run this model, as THIS role". The container then
# starts on SageMaker's machine and needs, and gets, exactly four things:
#
#   1. pull the image            (finrisk-train: the same image that trained the model also serves it)
#   2. read the model file       (models/* of the ML bucket)
#   3. write its own log group   (/aws/sagemaker/Endpoints/finrisk-<env>-fraud)
#   4. pre-prod and prod only: write Data Capture (capture/<env>/* of the ML bucket) -- every request and answer, kept for the monitor
#
# dev and sit are serverless endpoints, which cannot capture data, so their role has no write permission at all.
# The role is separate from the app's runtime role (iam.tf) on purpose: the app CALLS the endpoint, the endpoint RUNS the model.
# finrisk-ml-promote-<env> may hand over this role (PassRole, to SageMaker) and no other.

resource "aws_iam_role" "endpoint" {
  name = "${local.name}-endpoint"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # Only SageMaker working for THIS account may use the role (the "confused deputy" guard).
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })

  depends_on = [terraform_data.workspace_matches_env]
}

resource "aws_iam_role_policy" "endpoint" {
  name = "${local.name}-endpoint"
  role = aws_iam_role.endpoint.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          # "Log in to ECR" has no resource to name; the pull actions below are limited to the one repository.
          Sid      = "EcrLogin"
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = "*"
        },
        {
          Sid      = "PullTheModelImage"
          Effect   = "Allow"
          Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
          Resource = "arn:aws:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/${var.project}-train"
        },
        {
          # The registered model's model.tar.gz lives under models/ (written by the training job).
          Sid      = "ReadTheModelFile"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = "arn:aws:s3:::${local.ml_bucket}/models/*"
        },
        {
          Sid       = "ListTheModelsFolder"
          Effect    = "Allow"
          Action    = ["s3:ListBucket"]
          Resource  = "arn:aws:s3:::${local.ml_bucket}"
          Condition = { StringLike = { "s3:prefix" = ["models/*"] } }
        },
        {
          # The endpoint's own log group, named after the endpoint. No other environment's.
          Sid    = "WriteTheEndpointLogs"
          Effect = "Allow"
          Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
          Resource = [
            "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/Endpoints/${local.endpoint_name}",
            "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/Endpoints/${local.endpoint_name}:*",
          ]
        },
      ],
      local.realtime_endpoint ? [
        {
          # Data Capture: SageMaker copies each request and response into this folder (JSON lines, one file per few minutes).
          Sid      = "WriteDataCapture"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = "arn:aws:s3:::${local.ml_bucket}/capture/${var.env}/*"
        },
        {
          # The blue/green guardrail: while the new fleet takes traffic, SageMaker reads the auto-rollback alarms
          # (finrisk-<env>-endpoint-5xx / -latency) AS THIS ROLE. Without this the read is denied, the guardrail fails closed
          # and every update rolls back, although both alarms are OK: the first live blue/green (21 Oct 2026, CloudTrail:
          # "finrisk-pre-prod-endpoint/SageMaker is not authorized to perform: cloudwatch:DescribeAlarms on resource: null").
          # Resource "*": AWS evaluated the call without an alarm ARN, so a name-scoped grant would not match. Read-only.
          Sid      = "ReadTheRollbackAlarms"
          Effect   = "Allow"
          Action   = ["cloudwatch:DescribeAlarms"]
          Resource = "*"
        },
      ] : [],
    )
  })
}

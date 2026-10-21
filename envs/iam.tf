# The identity the RUNNING app wears: one role per environment, least privilege.
# Lambda calls it the execution role; ECS calls it the task role. Both can wear the same kind of role, so the trust
# policy names both services and the compute (finrisk-app's deploy) decides which one uses it.

resource "aws_iam_role" "runtime" {
  name = "${local.name}-runtime"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["lambda.amazonaws.com", "ecs-tasks.amazonaws.com"] }
      Action    = "sts:AssumeRole"
    }]
  })

  depends_on = [terraform_data.workspace_matches_env]
}

resource "aws_iam_role_policy" "runtime" {
  name = "${local.name}-runtime"
  role = aws_iam_role.runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 1. Write its OWN log group (not "logs:*" on "*").
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.app.arn}:*"
      },
      {
        # 2. Read its OWN bucket (and no other environment's).
        Sid      = "ReadOwnBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.env.arn}/*"
      },
      {
        Sid      = "ListOwnBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.env.arn
      },
      {
        # 3. Read the registered MODEL: <ML bucket>/models/* and nothing else in that bucket (not the training data).
        Sid      = "ReadModelArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${local.ml_bucket}/models/*"
      },
      {
        Sid       = "ListModelArtifacts"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = "arn:aws:s3:::${local.ml_bucket}"
        Condition = { StringLike = { "s3:prefix" = ["models/*"] } }
      },
      {
        # 4. Read the published INDEX: <KB bucket>/indexes/* and nothing else.
        Sid      = "ReadIndexArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${local.kb_bucket}/indexes/*"
      },
      {
        Sid       = "ListIndexArtifacts"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = "arn:aws:s3:::${local.kb_bucket}"
        Condition = { StringLike = { "s3:prefix" = ["indexes/*"] } }
      },
      {
        # 5. Call TWO Bedrock models in this Region -- this replaces an API key: the chat model and the embedding model.
        #    Foundation models only: cross-Region inference profiles (a different ARN) are not available on the Free plan.
        Sid    = "InvokeBedrockModels"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:${data.aws_region.current.region}::foundation-model/${var.bedrock_chat_model_id}",
          "arn:aws:bedrock:${data.aws_region.current.region}::foundation-model/${var.bedrock_embedding_model_id}",
        ]
      },
      {
        # 6. Read the pointers: which model and which index THIS environment serves (and the shared names).
        #    This is how a new model or index reaches the running service without a new image.
        Sid    = "ReadPointersAndSharedNames"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/${var.env}/*",
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/shared/*",
        ]
      },
      {
        # 7. Call THIS environment's model endpoint (and ask whether it is InService): the app no longer holds the model, it asks
        #    the endpoint. Exactly one endpoint, named after this environment; no other environment's, no other action.
        Sid      = "CallThisEnvironmentsModelEndpoint"
        Effect   = "Allow"
        Action   = ["sagemaker:InvokeEndpoint", "sagemaker:DescribeEndpoint"]
        Resource = "${local.arn_sm}:endpoint/${local.endpoint_name}"
      },
    ]
  })
}

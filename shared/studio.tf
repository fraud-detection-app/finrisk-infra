# SageMaker Studio (optional, on by default): the web page where the class SEES the pipeline graph, the model registry, model
# cards and endpoints. Nothing runs in it. Terraform creates a DOMAIN (the Studio "workspace") and ONE user profile, and no
# spaces or apps: students' notebooks (if anyone opens one) are theirs to delete, and bill by the hour while they run.
#
# What it costs when nobody uses it: the domain's home file system (EFS) bytes. `retention_policy.home_efs_file_system =
# "Delete"` makes `terraform destroy` delete that file system too (the default would keep it, and keep billing).
#
# Needs the account's DEFAULT VPC (every new account has one unless somebody deleted it). No default VPC? Set
# create_studio_domain = false; everything else works without Studio.

data "aws_vpc" "default" {
  count = var.create_studio_domain ? 1 : 0

  default = true
}

data "aws_subnets" "default" {
  count = var.create_studio_domain ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

# The identity Studio wears. READ-ONLY: it can look at SageMaker and read the ML bucket and MLflow, nothing else. (To run a
# notebook or a job from Studio, an admin would give it more; the course does not need that.)
resource "aws_iam_role" "studio" {
  count = var.create_studio_domain ? 1 : 0

  name = "${var.project}-studio"

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

resource "aws_iam_role_policy" "studio" {
  count = var.create_studio_domain ? 1 : 0

  name = "${var.project}-studio"
  role = aws_iam_role.studio[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Studio's pages list and describe everything (pipelines, registry, endpoints, feature groups, experiments, ...). The
        # list calls have no resource to name; every action here only READS.
        Sid      = "LookAtSageMaker"
        Effect   = "Allow"
        Action   = ["sagemaker:Describe*", "sagemaker:List*", "sagemaker:Get*", "sagemaker:Search", "sagemaker:BatchGetRecord"]
        Resource = "*"
      },
      {
        Sid      = "ReadTheMlBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.ml.arn}/*"
      },
      {
        Sid      = "ListTheMlBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.ml.arn
      },
      {
        # Open the MLflow UI from Studio and read the runs.
        Sid      = "OpenMlflow"
        Effect   = "Allow"
        Action   = ["sagemaker:CallMlflowAppApi", "sagemaker:CreatePresignedMlflowAppUrl", "sagemaker:DescribeMlflowApp"]
        Resource = "${local.arn_sm}:mlflow-app/*"
      },
      {
        # Pipeline steps' logs.
        Sid    = "ReadSageMakerLogs"
        Effect = "Allow"
        Action = ["logs:DescribeLogStreams", "logs:GetLogEvents"]
        Resource = [
          "arn:aws:logs:${local.region}:${local.acct}:log-group:/aws/sagemaker/*",
        ]
      },
    ]
  })
}

resource "aws_sagemaker_domain" "studio" {
  count = var.create_studio_domain ? 1 : 0

  domain_name = "${var.project}-studio"
  auth_mode   = "IAM"
  vpc_id      = data.aws_vpc.default[0].id
  subnet_ids  = data.aws_subnets.default[0].ids

  default_user_settings {
    execution_role = aws_iam_role.studio[0].arn
  }

  # `terraform destroy` deletes the home file system too. Without this, EFS would outlive the domain and keep billing.
  retention_policy {
    home_efs_file_system = "Delete"
  }

  # AWS answers with an empty `default_user_settings.studio_web_portal_settings {}` block that this file never sets, so
  # without this every plan wants to "remove" it: a change that changes nothing, and a nightly drift failure (seen on the
  # first live plan after the domain was created, 20 Oct 2026).
  lifecycle {
    ignore_changes = [default_user_settings[0].studio_web_portal_settings]
  }

  depends_on = [aws_iam_role_policy.studio]
}

resource "aws_sagemaker_user_profile" "instructor" {
  count = var.create_studio_domain ? 1 : 0

  domain_id         = aws_sagemaker_domain.studio[0].id
  user_profile_name = "instructor"
}

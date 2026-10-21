# Building blocks the role policies (roles_*.tf) are made of. Nothing is created here -- these are only values.
#
# Rule of this repository: a role names the resource it may touch BY NAME (finrisk-<env>-*, /finrisk/<env>/*,
# the exact bucket). Where AWS has no resource to name, the statement says so in a comment.

locals {
  arn_s3   = "arn:aws:s3:::"
  arn_ecr  = "arn:aws:ecr:${local.region}:${local.acct}:repository"
  arn_role = "arn:aws:iam::${local.acct}:role"
  arn_ssm  = "arn:aws:ssm:${local.region}:${local.acct}:parameter"
  arn_sm   = "arn:aws:sagemaker:${local.region}:${local.acct}"
  arn_logs = "arn:aws:logs:${local.region}:${local.acct}:log-group"
  arn_ecs  = "arn:aws:ecs:${local.region}:${local.acct}"

  arn_cw     = "arn:aws:cloudwatch:${local.region}:${local.acct}"
  arn_glue   = "arn:aws:glue:${local.region}:${local.acct}"
  arn_athena = "arn:aws:athena:${local.region}:${local.acct}"
  arn_sched  = "arn:aws:scheduler:${local.region}:${local.acct}"
  arn_evts   = "arn:aws:events:${local.region}:${local.acct}"

  # The two SageMaker Pipelines (made by finrisk-ml, never by Terraform) and the ARNs of their executions.
  # A pipeline EXECUTION is its own resource type in IAM: pipeline/<name>/execution/<id>.
  pipeline_arns           = ["${local.arn_sm}:pipeline/${local.train_pipeline}", "${local.arn_sm}:pipeline/${local.monitor_pipeline}"]
  pipeline_execution_arns = ["${local.arn_sm}:pipeline/${local.train_pipeline}/execution/*", "${local.arn_sm}:pipeline/${local.monitor_pipeline}/execution/*"]

  # The MLflow App's ARN ends in an id AWS chooses (mlflow-app/<id>), so it cannot be named before the app exists.
  # One app per account; `mlflow-app/*` is the narrowest ARN that works from bootstrap.
  mlflow_app_arn_pattern = "${local.arn_sm}:mlflow-app/*"

  # The ML bucket's prefixes (folders) and who may do what with them is spelled out in shared/ml.tf; the names:
  feature_group_arn = "${local.arn_sm}:feature-group/${local.feature_group}"

  # The only AWS-managed policies ECS Express Mode needs -- the pipeline may attach these two and nothing else.
  ecs_managed_policies = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
    "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices",
  ]

  # Pushing an image to ONE repository (the "log in to ECR" call is separate: it has no resource to name).
  ecr_push_actions = [
    "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
    "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
    "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:ListImages",
  ]

  # Pulling / looking at images of ONE repository.
  ecr_read_actions = [
    "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:GetRepositoryPolicy",
    "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:ListImages", "ecr:ListTagsForResource",
  ]

  # Where each stack keeps its state. The S3 backend writes <key> (default workspace) or env:/<workspace>/<key>,
  # plus a <that>.tflock file while a run is in progress (use_lockfile = true).
  #   scope  = what the role may write      default_key = the "default workspace" object `terraform init` looks at
  infra_scopes = merge(
    { shared = { object = "infra/shared.tfstate", default_key = "infra/shared.tfstate", workspace = false } },
    { for e in local.environments : e => { object = "env:/${e}/infra/env.tfstate", default_key = "infra/env.tfstate", workspace = true } },
  )
  app_scopes = {
    for e in local.environments : e => { object = "env:/${e}/app/service.tfstate", default_key = "app/service.tfstate", workspace = true }
  }

  # "State of this scope only": read/write/lock its own object, read the (empty) default workspace so init says
  # "not found" instead of "access denied", and list workspace NAMES (listing shows names, never contents).
  infra_state = {
    for scope, s in local.infra_scopes : scope => concat(
      [
        {
          Sid      = "StateOfThisScope"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = ["${local.arn_s3}${local.state_bucket}/${s.object}", "${local.arn_s3}${local.state_bucket}/${s.object}.tflock"]
        },
        {
          Sid       = "ListWorkspaceNames"
          Effect    = "Allow"
          Action    = ["s3:ListBucket"]
          Resource  = "${local.arn_s3}${local.state_bucket}"
          Condition = { StringLike = { "s3:prefix" = ["env:/*", s.default_key] } }
        },
      ],
      [for x in [{
        Sid      = "StateDefaultWorkspaceReadOnly"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${local.arn_s3}${local.state_bucket}/${s.default_key}"
      }] : x if s.workspace],
    )
  }

  app_state = {
    for scope, s in local.app_scopes : scope => [
      {
        Sid      = "StateOfThisEnvironment"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${local.arn_s3}${local.state_bucket}/${s.object}", "${local.arn_s3}${local.state_bucket}/${s.object}.tflock"]
      },
      {
        Sid      = "StateDefaultWorkspaceReadOnly"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${local.arn_s3}${local.state_bucket}/${s.default_key}"
      },
      {
        Sid       = "ListWorkspaceNames"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = "${local.arn_s3}${local.state_bucket}"
        Condition = { StringLike = { "s3:prefix" = ["env:/*", s.default_key] } }
      },
    ]
  }

  # Parameter Store: reading a family of parameters, writing one family (or one parameter).
  ssm_read_actions  = ["ssm:GetParameter", "ssm:GetParameters"]
  ssm_write_actions = ["ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"]
}

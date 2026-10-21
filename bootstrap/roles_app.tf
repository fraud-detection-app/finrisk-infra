# Roles of the finrisk-app repository (the risk service).
#
#   role                      who may become it                                  what it may do
#   finrisk-app-build         ...finrisk-app:ref:refs/heads/main                 push images to ONE ECR repository
#   finrisk-app-deploy-<env>  ...finrisk-app:environment:<env>   (x4)            deploy the service stack of ONE environment
#
# The build role has no environment: the build job runs on main only, and the sub says so. A deploy job names its
# Environment, so the sub is "environment:<env>" -- and GitHub only starts that job from main, and (pre-prod, prod)
# only after a reviewer approves.

locals {
  app_build_statements = [
    {
      Sid      = "EcrLogin"
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*" # no resource exists for "log in to ECR"
    },
    {
      Sid      = "PushAndFindImagesInOneRepository"
      Effect   = "Allow"
      Action   = local.ecr_push_actions
      Resource = "${local.arn_ecr}/${local.ecr_app}"
    },
  ]

  # One deploy role per environment. The service stack (finrisk-app/deploy/terraform) creates the Lambda function
  # or the Express Mode service, and writes the URL into Parameter Store. It does NOT create roles, buckets or log
  # groups -- finrisk-infra did that, and this role may only hand the runtime roles to the compute service.
  app_deploy_statements = {
    for e in local.environments : e => concat(
      local.app_state[e],
      [
        {
          # Actions broad, resource exact: every Lambda action, but only on the function finrisk-<env>.
          Sid      = "OwnLambdaFunction"
          Effect   = "Allow"
          Action   = ["lambda:*"]
          Resource = "arn:aws:lambda:${local.region}:${local.acct}:function:${var.project}-${e}"
        },
        {
          Sid    = "OwnExpressService"
          Effect = "Allow"
          Action = [
            "ecs:CreateExpressGatewayService", "ecs:UpdateExpressGatewayService", "ecs:DeleteExpressGatewayService",
            "ecs:DescribeExpressGatewayService", "ecs:DescribeServices", "ecs:TagResource", "ecs:UntagResource", "ecs:ListTagsForResource",
          ]
          Resource = "${local.arn_ecs}:service/*/${var.project}-${e}"
        },
        {
          # Express creates its cluster and task definition and names them itself, so these two cannot be named.
          Sid    = "ExpressClusterAndTaskDefinition"
          Effect = "Allow"
          Action = [
            "ecs:CreateCluster", "ecs:DescribeClusters", "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition",
            "ecs:DeleteTaskDefinitions", "ecs:TagResource", "ecs:ListTagsForResource",
          ]
          Resource = ["${local.arn_ecs}:cluster/*", "${local.arn_ecs}:task-definition/*"]
        },
        {
          # Handing finrisk-<env>-runtime / -ecs-execution / -ecs-infrastructure to the compute service, and only to it.
          Sid       = "PassOwnRolesToTheComputeService"
          Effect    = "Allow"
          Action    = ["iam:PassRole"]
          Resource  = "${local.arn_role}/${var.project}-${e}-*"
          Condition = { StringEquals = { "iam:PassedToService" = ["lambda.amazonaws.com", "ecs-tasks.amazonaws.com", "ecs.amazonaws.com"] } }
        },
        {
          Sid      = "ReadOwnRoles"
          Effect   = "Allow"
          Action   = ["iam:GetRole", "iam:ListAttachedRolePolicies", "iam:ListRolePolicies"]
          Resource = "${local.arn_role}/${var.project}-${e}-*"
        },
        {
          # Lambda and Express check that the CALLER may read the image they are told to run.
          Sid      = "ReadTheAppImages"
          Effect   = "Allow"
          Action   = local.ecr_read_actions
          Resource = "${local.arn_ecr}/${local.ecr_app}"
        },
        {
          # The names finrisk-infra published (runtime role, log group, bucket) ...
          Sid      = "ReadSharedAndOwnParameters"
          Effect   = "Allow"
          Action   = local.ssm_read_actions
          Resource = ["${local.arn_ssm}/${var.project}/shared/*", "${local.arn_ssm}/${var.project}/${e}/*"]
        },
        {
          # ... and the one it writes: the service URL, for the model and index pipelines' smoke checks.
          Sid      = "WriteTheServiceUrl"
          Effect   = "Allow"
          Action   = concat(["ssm:PutParameter", "ssm:DeleteParameter"], ["ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"])
          Resource = "${local.arn_ssm}/${var.project}/${e}/app_url"
        },
        {
          # Read the app's log when a smoke test fails.
          Sid      = "ReadOwnLogs"
          Effect   = "Allow"
          Action   = ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents"]
          Resource = ["${local.arn_logs}:/app/${var.project}-${e}", "${local.arn_logs}:/app/${var.project}-${e}:*"]
        },
        {
          # Terraform's refresh: read-only Describe calls with nothing to name (the load balancer and security group
          # Express builds, Lambda's tags). None can change anything.
          Sid    = "ReadOnlyRefresh"
          Effect = "Allow"
          Action = [
            "ec2:Describe*", "elasticloadbalancing:Describe*", "application-autoscaling:Describe*",
            "ecs:Describe*", "ecs:List*", "logs:DescribeLogGroups", "ssm:DescribeParameters",
          ]
          Resource = "*"
        },
      ],
    )
  }

  app_roles = merge(
    {
      "${var.project}-app-build" = {
        repo        = "app"
        subject     = "ref:refs/heads/main"
        description = "finrisk-app main branch: the build job pushes the release image to ECR. Nothing else."
        statements  = local.app_build_statements
      }
    },
    {
      for e in local.environments : "${var.project}-app-deploy-${e}" => {
        repo        = "app"
        subject     = "environment:${e}"
        description = "finrisk-app environment ${e}: deploys the service stack of ${e} (workspace ${e}) and nothing else."
        statements  = local.app_deploy_statements[e]
      }
    },
  )
}

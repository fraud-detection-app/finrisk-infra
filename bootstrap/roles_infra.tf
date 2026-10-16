# Roles of the finrisk-infra repository: one that only LOOKS (pull requests), one that only looks on a schedule
# (drift), and five that CHANGE things (one per scope: shared, dev, sit, pre-prod, prod).
#
#   role                       who may become it (the token's `sub`)                what it may do
#   finrisk-infra-plan         ...finrisk-infra:pull_request                         read state + Describe/Get/List (no writes)
#   finrisk-infra-drift        ...finrisk-infra:ref:refs/heads/main                  the same read-only policy, for the nightly run
#   finrisk-infra-apply-<s>    ...finrisk-infra:environment:infra-<s>                create/update the resources of scope <s>
#
# `subject` below is everything after "repo:<org>/<repo>:" -- oidc.tf puts the rest in front.

locals {
  # ---- read-only: shared by plan and drift. Every action is a read; none can change anything.
  plan_statements = [
    {
      Sid    = "ReadStateObjects"
      Effect = "Allow"
      Action = ["s3:GetObject"]
      Resource = concat(
        ["${local.arn_s3}${local.state_bucket}/infra/shared.tfstate", "${local.arn_s3}${local.state_bucket}/infra/env.tfstate"],
        ["${local.arn_s3}${local.state_bucket}/env:/*/infra/env.tfstate"],
      )
    },
    {
      Sid       = "ListWorkspaceNames"
      Effect    = "Allow"
      Action    = ["s3:ListBucket"]
      Resource  = "${local.arn_s3}${local.state_bucket}"
      Condition = { StringLike = { "s3:prefix" = ["env:/*", "infra/*"] } }
    },
    {
      # Bucket SETTINGS (not the files inside): terraform refresh reads a dozen of them per bucket.
      Sid    = "ReadBucketSettings"
      Effect = "Allow"
      Action = ["s3:Get*", "s3:List*"]
      Resource = concat(
        ["${local.arn_s3}${local.ml_bucket}", "${local.arn_s3}${local.kb_bucket}"],
        [for e in local.environments : "${local.arn_s3}${local.env_bucket[e]}"],
      )
    },
    {
      Sid      = "ReadRoles"
      Effect   = "Allow"
      Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:ListRoleTags"]
      Resource = "${local.arn_role}/${var.project}-*"
    },
    {
      Sid      = "ReadRepositories"
      Effect   = "Allow"
      Action   = ["ecr:DescribeRepositories", "ecr:ListTagsForResource", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy"]
      Resource = ["${local.arn_ecr}/${local.ecr_app}", "${local.arn_ecr}/${local.ecr_train}"]
    },
    {
      Sid      = "ReadModelGroup"
      Effect   = "Allow"
      Action   = ["sagemaker:DescribeModelPackageGroup", "sagemaker:ListTags"]
      Resource = "${local.arn_sm}:model-package-group/${local.model_group}"
    },
    {
      Sid      = "ReadParameters"
      Effect   = "Allow"
      Action   = concat(local.ssm_read_actions, ["ssm:ListTagsForResource"])
      Resource = "${local.arn_ssm}/${var.project}/*"
    },
    {
      # No resource can be named for "list my log groups / parameters": the answer is names only.
      Sid      = "ListNamesOnly"
      Effect   = "Allow"
      Action   = ["ssm:DescribeParameters", "logs:DescribeLogGroups"]
      Resource = "*"
    },
    {
      Sid      = "ReadLogGroupTags"
      Effect   = "Allow"
      Action   = ["logs:ListTagsForResource", "logs:ListTagsLogGroup"]
      Resource = ["${local.arn_logs}:/app/${var.project}-*", "${local.arn_logs}:/app/${var.project}-*:*"]
    },
  ]

  # ---- apply roles. Common to the four environments (envs/ stack): bucket, log group, three roles, parameters.
  apply_env_statements = {
    for e in local.environments : e => concat(
      local.infra_state[e],
      [
        {
          Sid    = "OwnBucket"
          Effect = "Allow"
          Action = [
            "s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketVersioning", "s3:PutBucketPublicAccessBlock",
            "s3:PutBucketTagging", "s3:DeleteBucketTagging", "s3:Get*", "s3:List*",
          ]
          Resource = "${local.arn_s3}${local.env_bucket[e]}"
        },
        {
          # finrisk-<env>-runtime, -ecs-execution, -ecs-infrastructure. No other role name matches the pattern.
          Sid    = "OwnRoles"
          Effect = "Allow"
          Action = [
            "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
            "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
            "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
            "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
          ]
          Resource = "${local.arn_role}/${var.project}-${e}-*"
        },
        {
          # Only the two AWS-managed policies ECS Express needs -- not AdministratorAccess.
          Sid       = "AttachOnlyTheEcsManagedPolicies"
          Effect    = "Allow"
          Action    = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
          Resource  = "${local.arn_role}/${var.project}-${e}-*"
          Condition = { ArnEquals = { "iam:PolicyARN" = local.ecs_managed_policies } }
        },
        {
          Sid    = "OwnLogGroup"
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
            "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
            "logs:TagLogGroup", "logs:UntagLogGroup",
          ]
          Resource = ["${local.arn_logs}:/app/${var.project}-${e}", "${local.arn_logs}:/app/${var.project}-${e}:*"]
        },
        {
          Sid      = "OwnParameters"
          Effect   = "Allow"
          Action   = concat(local.ssm_read_actions, local.ssm_write_actions)
          Resource = "${local.arn_ssm}/${var.project}/${e}/*"
        },
        {
          # envs/ reads the names shared/ published (the ML and KB buckets) -- read only.
          Sid      = "ReadSharedParameters"
          Effect   = "Allow"
          Action   = local.ssm_read_actions
          Resource = "${local.arn_ssm}/${var.project}/shared/*"
        },
        {
          Sid      = "ListNamesOnly"
          Effect   = "Allow"
          Action   = ["ssm:DescribeParameters", "logs:DescribeLogGroups"]
          Resource = "*"
        },
      ],
    )
  }

  # ---- apply-shared: two registries, the ML and KB buckets, the SageMaker role and registry group, /finrisk/shared/*.
  apply_shared_statements = concat(
    local.infra_state["shared"],
    [
      {
        Sid    = "OwnRepositories"
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository", "ecr:DeleteRepository", "ecr:DescribeRepositories", "ecr:ListTagsForResource",
          "ecr:TagResource", "ecr:UntagResource", "ecr:GetRepositoryPolicy", "ecr:GetLifecyclePolicy",
          "ecr:PutLifecyclePolicy", "ecr:DeleteLifecyclePolicy", "ecr:PutImageScanningConfiguration", "ecr:PutImageTagMutability",
          # The repository policy that lets Lambda pull finrisk-app (shared/ecr.tf). Only this role may write it.
          "ecr:SetRepositoryPolicy", "ecr:DeleteRepositoryPolicy",
        ]
        Resource = ["${local.arn_ecr}/${local.ecr_app}", "${local.arn_ecr}/${local.ecr_train}"]
      },
      {
        Sid    = "OwnBuckets"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketVersioning", "s3:PutBucketPublicAccessBlock",
          "s3:PutLifecycleConfiguration", "s3:PutBucketTagging", "s3:DeleteBucketTagging", "s3:Get*", "s3:List*",
        ]
        Resource = ["${local.arn_s3}${local.ml_bucket}", "${local.arn_s3}${local.kb_bucket}"]
      },
      {
        # Exactly one role: the one a SageMaker training job wears.
        Sid    = "OwnSageMakerRole"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
          "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
        ]
        Resource = "${local.arn_role}/${local.sagemaker_role_name}"
      },
      {
        Sid      = "OwnModelGroup"
        Effect   = "Allow"
        Action   = ["sagemaker:CreateModelPackageGroup", "sagemaker:DeleteModelPackageGroup", "sagemaker:DescribeModelPackageGroup", "sagemaker:AddTags", "sagemaker:DeleteTags", "sagemaker:ListTags"]
        Resource = "${local.arn_sm}:model-package-group/${local.model_group}"
      },
      {
        Sid      = "OwnSharedParameters"
        Effect   = "Allow"
        Action   = concat(local.ssm_read_actions, local.ssm_write_actions)
        Resource = "${local.arn_ssm}/${var.project}/shared/*"
      },
      {
        Sid      = "ListNamesOnly"
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "*"
      },
    ],
  )

  infra_roles = merge(
    {
      "${var.project}-infra-plan" = {
        repo        = "infra"
        subject     = "pull_request"
        description = "finrisk-infra pull requests: terraform plan for shared and every environment. Read-only."
        statements  = local.plan_statements
      }
      "${var.project}-infra-drift" = {
        repo        = "infra"
        subject     = "ref:refs/heads/main"
        description = "finrisk-infra nightly drift check on main: terraform plan only. Read-only (same policy as the plan role)."
        statements  = local.plan_statements
      }
      "${var.project}-infra-apply-shared" = {
        repo        = "infra"
        subject     = "environment:infra-shared"
        description = "finrisk-infra environment infra-shared: applies shared/ (registries, ML and KB buckets, SageMaker role and registry group) and nothing else."
        statements  = local.apply_shared_statements
      }
    },
    {
      for e in local.environments : "${var.project}-infra-apply-${e}" => {
        repo        = "infra"
        subject     = "environment:infra-${e}"
        description = "finrisk-infra environment infra-${e}: applies envs/ in workspace ${e} (bucket, log group, roles, parameters) and nothing else."
        statements  = local.apply_env_statements[e]
      }
    },
  )
}

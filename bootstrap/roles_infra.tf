# Roles of the finrisk-infra repository: one that only LOOKS (pull requests), one that only looks on a schedule
# (drift), and five that CHANGE things (one per scope: shared, dev, sit, pre-prod, prod).
#
#   role                       who may become it (the token's `sub`)                what it may do
#   finrisk-infra-plan         ...finrisk-infra:pull_request                         read state + Describe/Get/List (no writes)
#   finrisk-infra-drift        ...finrisk-infra:ref:refs/heads/main                  the same read-only policy, for the nightly run
#   finrisk-infra-apply-<s>    ...finrisk-infra:environment:infra-<s>                create/update the resources of scope <s>
#
# Week 13b grew what the apply roles may create: apply-shared also owns the Feature Store group, the MLflow App, the Studio
# domain, the Glue database + labels table, the Athena workgroup, the EventBridge schedules and rule, and FIVE role names
# (each handed to ITS service only); apply-<env> also owns the endpoint role and the CloudWatch alarms named finrisk-<env>-*.
# The plan and drift roles can read all of it (Describe/Get/List only). bootstrap/oidc.tf lists what is broad and why.
#
# `subject` below is everything after the repository's prefix ("repo:<org>/<repo>", or its immutable form with the numeric
# ids) and the colon -- oidc.tf puts the prefix in front.

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
    {
      # Week 13b: the Feature Store group, the MLflow App and the Studio domain + profile (their ids are chosen by AWS).
      Sid    = "ReadSageMakerResources"
      Effect = "Allow"
      Action = ["sagemaker:DescribeFeatureGroup", "sagemaker:DescribeMlflowApp", "sagemaker:DescribeDomain", "sagemaker:DescribeUserProfile", "sagemaker:ListTags"]
      Resource = [
        local.feature_group_arn, local.mlflow_app_arn_pattern,
        "${local.arn_sm}:domain/*", "${local.arn_sm}:user-profile/*",
      ]
    },
    {
      Sid    = "ReadTheDataCatalogAndTheWorkgroup"
      Effect = "Allow"
      Action = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:GetTags", "athena:GetWorkGroup", "athena:ListTagsForResource"]
      Resource = [
        "${local.arn_glue}:catalog", "${local.arn_glue}:database/${local.glue_database}", "${local.arn_glue}:table/${local.glue_database}/*",
        "${local.arn_athena}:workgroup/${local.athena_workgroup}",
      ]
    },
    {
      Sid    = "ReadSchedulesRulesAndAlarms"
      Effect = "Allow"
      Action = [
        "scheduler:GetScheduleGroup", "scheduler:GetSchedule", "scheduler:ListTagsForResource",
        "events:DescribeRule", "events:ListTargetsByRule", "events:ListTagsForResource",
        "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
      ]
      Resource = [
        "${local.arn_sched}:schedule-group/${var.project}", "${local.arn_sched}:schedule/${var.project}/*",
        "${local.arn_evts}:rule/${var.project}-*", "${local.arn_cw}:alarm:${var.project}-*",
      ]
    },
    {
      # The Studio domain lives in the default network: the data sources read the VPC and its subnets. Names and settings only.
      Sid      = "ReadTheDefaultNetwork"
      Effect   = "Allow"
      Action   = ["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeVpcAttribute"]
      Resource = "*"
    },
  ]

  # ---- apply roles. Common to the four environments (envs/ stack): bucket, log group, the roles (runtime, endpoint, ECS), alarms, parameters.
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
          # finrisk-<env>-runtime, -endpoint, -ecs-execution, -ecs-infrastructure. No other role name matches the pattern.
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
          # Week 13b: the endpoint guardrail alarms (pre-prod, prod) and the three prod model alarms. Every one is named
          # finrisk-<env>-..., so this role cannot touch another environment's alarms.
          Sid      = "OwnAlarms"
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource", "cloudwatch:ListTagsForResource"]
          Resource = "${local.arn_cw}:alarm:${var.project}-${e}-*"
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

  # ---- apply-shared: two registries, the ML and KB buckets, the five shared roles, the registry group, the Feature Store
  # group, the MLflow App, the Studio domain, the Glue database + labels table, the Athena workgroup, the EventBridge
  # schedules and rule, and /finrisk/shared/*.
  shared_role_arns = [
    "${local.arn_role}/${local.sagemaker_role_name}", "${local.arn_role}/${local.mlflow_role_name}", "${local.arn_role}/${local.studio_role_name}",
    "${local.arn_role}/${local.scheduler_role_name}", "${local.arn_role}/${local.events_role_name}",
  ]

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
        # Exactly five roles: what a SageMaker job / pipeline wears (and the Feature Store writes with), what the MLflow App wears,
        # what Studio wears, what EventBridge Scheduler wears, what the EventBridge rule wears. No other role name matches.
        Sid    = "OwnTheSharedRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
          "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
        ]
        Resource = local.shared_role_arns
      },
      {
        # Handing a role to a service needs PassRole -- each role only to ITS service.
        Sid       = "PassTheSageMakerRolesToSageMaker"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = ["${local.arn_role}/${local.sagemaker_role_name}", "${local.arn_role}/${local.mlflow_role_name}", "${local.arn_role}/${local.studio_role_name}"]
        Condition = { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } }
      },
      {
        Sid       = "PassTheSchedulerRoleToScheduler"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = "${local.arn_role}/${local.scheduler_role_name}"
        Condition = { StringEquals = { "iam:PassedToService" = "scheduler.amazonaws.com" } }
      },
      {
        Sid       = "PassTheEventsRoleToEventBridge"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = "${local.arn_role}/${local.events_role_name}"
        Condition = { StringEquals = { "iam:PassedToService" = "events.amazonaws.com" } }
      },
      {
        Sid      = "OwnModelGroup"
        Effect   = "Allow"
        Action   = ["sagemaker:CreateModelPackageGroup", "sagemaker:DeleteModelPackageGroup", "sagemaker:DescribeModelPackageGroup", "sagemaker:AddTags", "sagemaker:DeleteTags", "sagemaker:ListTags"]
        Resource = "${local.arn_sm}:model-package-group/${local.model_group}"
      },
      {
        Sid      = "OwnFeatureGroup"
        Effect   = "Allow"
        Action   = ["sagemaker:CreateFeatureGroup", "sagemaker:DeleteFeatureGroup", "sagemaker:DescribeFeatureGroup", "sagemaker:UpdateFeatureGroup", "sagemaker:AddTags", "sagemaker:DeleteTags", "sagemaker:ListTags"]
        Resource = local.feature_group_arn
      },
      {
        Sid      = "OwnMlflowApp"
        Effect   = "Allow"
        Action   = ["sagemaker:CreateMlflowApp", "sagemaker:DeleteMlflowApp", "sagemaker:DescribeMlflowApp", "sagemaker:UpdateMlflowApp", "sagemaker:AddTags", "sagemaker:DeleteTags", "sagemaker:ListTags"]
        Resource = local.mlflow_app_arn_pattern
      },
      {
        # A domain and a profile have ids AWS chooses (d-xxxx), so they can only be named by a pattern: broad on purpose, see oidc.tf.
        Sid    = "OwnStudioDomainAndProfile"
        Effect = "Allow"
        Action = [
          "sagemaker:CreateDomain", "sagemaker:DeleteDomain", "sagemaker:DescribeDomain", "sagemaker:UpdateDomain",
          "sagemaker:CreateUserProfile", "sagemaker:DeleteUserProfile", "sagemaker:DescribeUserProfile", "sagemaker:UpdateUserProfile",
          "sagemaker:AddTags", "sagemaker:DeleteTags", "sagemaker:ListTags",
        ]
        Resource = ["${local.arn_sm}:domain/*", "${local.arn_sm}:user-profile/*"]
      },
      {
        # The domain lives in the default VPC: read it (names and settings only).
        Sid      = "ReadTheDefaultNetwork"
        Effect   = "Allow"
        Action   = ["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeVpcAttribute"]
        Resource = "*"
      },
      {
        # Database finrisk_ml: the labels table (Terraform) and the transactions table (the Feature Store creates it, and
        # deleting the database deletes the tables inside it).
        Sid    = "OwnTheDataCatalog"
        Effect = "Allow"
        Action = [
          "glue:CreateDatabase", "glue:DeleteDatabase", "glue:GetDatabase", "glue:GetDatabases", "glue:UpdateDatabase",
          "glue:CreateTable", "glue:DeleteTable", "glue:GetTable", "glue:GetTables", "glue:UpdateTable",
          "glue:TagResource", "glue:GetTags",
        ]
        Resource = ["${local.arn_glue}:catalog", "${local.arn_glue}:database/${local.glue_database}", "${local.arn_glue}:table/${local.glue_database}/*"]
      },
      {
        Sid      = "OwnTheAthenaWorkgroup"
        Effect   = "Allow"
        Action   = ["athena:CreateWorkGroup", "athena:DeleteWorkGroup", "athena:GetWorkGroup", "athena:UpdateWorkGroup", "athena:TagResource", "athena:UntagResource", "athena:ListTagsForResource"]
        Resource = "${local.arn_athena}:workgroup/${local.athena_workgroup}"
      },
      {
        Sid    = "OwnTheScheduleGroup"
        Effect = "Allow"
        Action = [
          "scheduler:CreateScheduleGroup", "scheduler:DeleteScheduleGroup", "scheduler:GetScheduleGroup", "scheduler:TagResource", "scheduler:UntagResource", "scheduler:ListTagsForResource",
          "scheduler:CreateSchedule", "scheduler:UpdateSchedule", "scheduler:DeleteSchedule", "scheduler:GetSchedule",
        ]
        Resource = ["${local.arn_sched}:schedule-group/${var.project}", "${local.arn_sched}:schedule/${var.project}/*"]
      },
      {
        Sid    = "OwnTheRetrainOnDriftRule"
        Effect = "Allow"
        Action = [
          "events:PutRule", "events:DeleteRule", "events:DescribeRule", "events:EnableRule", "events:DisableRule",
          "events:PutTargets", "events:RemoveTargets", "events:ListTargetsByRule", "events:TagResource", "events:UntagResource", "events:ListTagsForResource",
        ]
        Resource = "${local.arn_evts}:rule/${var.project}-retrain-on-drift"
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
        description = "finrisk-infra environment infra-shared: applies shared/ (registries, buckets, the shared roles, registry, Feature Store, MLflow, Studio, Glue/Athena, schedules) and nothing else."
        statements  = local.apply_shared_statements
      }
    },
    {
      for e in local.environments : "${var.project}-infra-apply-${e}" => {
        repo        = "infra"
        subject     = "environment:infra-${e}"
        description = "finrisk-infra environment infra-${e}: applies envs/ in workspace ${e} (bucket, log group, roles, alarms, parameters) and nothing else."
        statements  = local.apply_env_statements[e]
      }
    },
  )
}

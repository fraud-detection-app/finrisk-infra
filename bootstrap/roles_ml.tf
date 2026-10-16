# Roles of the finrisk-ml repository (training, registry, promotion of the model pointer).
#
#   role                       who may become it                                   what it may do
#   finrisk-ml-train           ...finrisk-ml:environment:ml                        build + push the training image, run SageMaker training, register Pending
#   finrisk-ml-approve         ...finrisk-ml:environment:model-approval            change a registry entry's approval status. Nothing else.
#   finrisk-ml-promote-<env>   ...finrisk-ml:environment:<env>    (x4)             write the model pointer of ONE environment
#
# Every Environment of finrisk-ml gets its role as the Environment secret AWS_ROLE_ARN (see outputs.tf).
#
# Train and approve are different roles on purpose: the job that trains a model cannot approve it.

locals {
  ml_group_arns = [
    "${local.arn_sm}:model-package-group/${local.model_group}",
    "${local.arn_sm}:model-package/${local.model_group}/*",
  ]

  ml_train_statements = [
    {
      Sid      = "EcrLogin"
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*" # no resource exists for "log in to ECR"
    },
    {
      Sid      = "PushTheTrainingImage"
      Effect   = "Allow"
      Action   = local.ecr_push_actions
      Resource = "${local.arn_ecr}/${local.ecr_train}"
    },
    {
      # The training image starts FROM a pinned finrisk-app image: reading it, never writing it.
      Sid      = "ReadTheAppImage"
      Effect   = "Allow"
      Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages", "ecr:DescribeRepositories"]
      Resource = "${local.arn_ecr}/${local.ecr_app}"
    },
    {
      Sid      = "TrainingJobs"
      Effect   = "Allow"
      Action   = ["sagemaker:CreateTrainingJob", "sagemaker:DescribeTrainingJob", "sagemaker:StopTrainingJob", "sagemaker:AddTags"]
      Resource = "${local.arn_sm}:training-job/${var.project}-train-*"
    },
    {
      # Register a model version (it starts Pending). Approving is the approve role's job, not this one's.
      Sid      = "RegisterModelVersions"
      Effect   = "Allow"
      Action   = ["sagemaker:CreateModelPackage", "sagemaker:DescribeModelPackage", "sagemaker:DescribeModelPackageGroup", "sagemaker:ListModelPackages", "sagemaker:AddTags"]
      Resource = local.ml_group_arns
    },
    {
      # The job wears the SageMaker execution role. Handing it over needs PassRole -- for that ONE role, to SageMaker.
      Sid       = "PassTheExecutionRoleToSageMaker"
      Effect    = "Allow"
      Action    = ["iam:PassRole"]
      Resource  = "${local.arn_role}/${local.sagemaker_role_name}"
      Condition = { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } }
    },
    {
      # The pipeline uploads training data; the TRAINING JOB (its own role) writes models/ and metrics/.
      Sid      = "UploadTrainingData"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
      Resource = "${local.arn_s3}${local.ml_bucket}/data/*"
    },
    {
      Sid      = "ReadModels"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${local.arn_s3}${local.ml_bucket}/models/*"
    },
    {
      # The pipeline's evaluate step reads AND writes the metrics files (the training job writes them too).
      Sid      = "ReadAndWriteMetrics"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "${local.arn_s3}${local.ml_bucket}/metrics/*"
    },
    {
      Sid      = "ListTheMlBucket"
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource = "${local.arn_s3}${local.ml_bucket}"
    },
    {
      # The evaluation gate compares the candidate with the champion: the model prod points at today.
      Sid      = "ReadSharedNamesAndTheProdModelPointer"
      Effect   = "Allow"
      Action   = local.ssm_read_actions
      Resource = ["${local.arn_ssm}/${var.project}/shared/*", "${local.arn_ssm}/${var.project}/prod/model"]
    },
    {
      # Read the training job's log when it fails.
      Sid      = "ReadTrainingLogs"
      Effect   = "Allow"
      Action   = ["logs:DescribeLogStreams", "logs:GetLogEvents"]
      Resource = ["${local.arn_logs}:/aws/sagemaker/TrainingJobs", "${local.arn_logs}:/aws/sagemaker/TrainingJobs:*"]
    },
  ]

  ml_approve_statements = [
    {
      Sid      = "ApproveOrRejectAModelVersion"
      Effect   = "Allow"
      Action   = ["sagemaker:UpdateModelPackage", "sagemaker:DescribeModelPackage", "sagemaker:ListModelPackages"]
      Resource = local.ml_group_arns
    },
  ]

  ml_promote_statements = {
    for e in local.environments : e => [
      {
        Sid      = "ReadTheRegistry"
        Effect   = "Allow"
        Action   = ["sagemaker:DescribeModelPackage", "sagemaker:ListModelPackages"]
        Resource = local.ml_group_arns
      },
      {
        # The pointer the service reads. This is the whole "deploy" of a model: one parameter.
        Sid      = "ReadAndMoveTheModelPointer"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "${local.arn_ssm}/${var.project}/${e}/model"
      },
      {
        Sid      = "ReadTheServiceUrl"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "${local.arn_ssm}/${var.project}/${e}/app_url"
      },
    ]
  }

  ml_roles = merge(
    {
      "${var.project}-ml-train" = {
        repo        = "ml"
        subject     = "environment:ml"
        description = "finrisk-ml environment ml: build the training image, run SageMaker training, register a Pending model version."
        statements  = local.ml_train_statements
      }
      "${var.project}-ml-approve" = {
        repo        = "ml"
        subject     = "environment:model-approval"
        description = "finrisk-ml environment model-approval (reviewer): change a model version's approval status. Nothing else."
        statements  = local.ml_approve_statements
      }
    },
    {
      for e in local.environments : "${var.project}-ml-promote-${e}" => {
        repo        = "ml"
        subject     = "environment:${e}"
        description = "finrisk-ml environment ${e}: point ${e} at a model version (/finrisk/${e}/model). Nothing else."
        statements  = local.ml_promote_statements[e]
      }
    },
  )
}

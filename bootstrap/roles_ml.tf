# Roles of the finrisk-ml repository (the model lifecycle: data platform, training pipeline, registry, endpoints, replay).
#
#   role                       who may become it                                   what it may do
#   finrisk-ml-train           ...finrisk-ml:environment:ml                        build + push the training image, create/start the two SageMaker
#                                                                                  Pipelines, run the backfill job, read what they wrote
#   finrisk-ml-approve         ...finrisk-ml:environment:model-approval            change a registry entry's approval status (and its model card). Nothing else.
#   finrisk-ml-promote-<env>   ...finrisk-ml:environment:<env>    (x4)             put ONE version of the model on ONE environment's endpoint
#   finrisk-ml-feedback        ...finrisk-ml:environment:simulation                the simulated outside world: replay traffic, write labels, record features
#
# Every Environment of finrisk-ml gets its role as the Environment secret AWS_ROLE_ARN (see outputs.tf).
#
# Train and approve are different roles on purpose: the job that trains a model cannot approve it. Since week 13b the
# training itself is not done by this role at all: the pipeline runs with the SageMaker execution role
# (finrisk-sagemaker-exec, made by shared/), and this role only STARTS the pipeline and hands that role over (PassRole).
# That is why CreateTrainingJob / CreateModelPackage are gone from it.
#
# The feedback role is the "customers and analysts" of the simulation: it can send traffic through the app, write labels
# under labels/source=feedback/ and features into the Feature Store -- and nothing near models/ or the pointers.

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
      # The two pipelines are plain JSON that finrisk-ml upserts (create, or update when it exists) and starts.
      Sid      = "UpsertAndStartThePipelines"
      Effect   = "Allow"
      Action   = ["sagemaker:CreatePipeline", "sagemaker:UpdatePipeline", "sagemaker:DescribePipeline", "sagemaker:StartPipelineExecution", "sagemaker:ListPipelineExecutions", "sagemaker:AddTags"]
      Resource = local.pipeline_arns
    },
    {
      # An execution is its own resource type (pipeline/<name>/execution/<id>): follow it step by step, stop it.
      Sid      = "FollowAndStopPipelineExecutions"
      Effect   = "Allow"
      Action   = ["sagemaker:DescribePipelineExecution", "sagemaker:ListPipelineExecutionSteps", "sagemaker:StopPipelineExecution"]
      Resource = local.pipeline_execution_arns
    },
    {
      # The one-off backfill (raw -> Feature Store) is a Processing job started directly, not through a pipeline.
      Sid      = "RunTheBackfillJob"
      Effect   = "Allow"
      Action   = ["sagemaker:CreateProcessingJob", "sagemaker:DescribeProcessingJob", "sagemaker:StopProcessingJob", "sagemaker:AddTags"]
      Resource = "${local.arn_sm}:processing-job/${var.project}-backfill-*"
    },
    {
      # Look at (never start) what a pipeline ran, to print why a step failed.
      Sid    = "DescribeJobsThePipelinesRan"
      Effect = "Allow"
      Action = ["sagemaker:DescribeProcessingJob", "sagemaker:DescribeTrainingJob", "sagemaker:DescribeHyperParameterTuningJob", "sagemaker:ListTrainingJobsForHyperParameterTuningJob"]
      Resource = [
        "${local.arn_sm}:processing-job/${var.project}-*",
        "${local.arn_sm}:training-job/${var.project}-*",
        "${local.arn_sm}:hyper-parameter-tuning-job/${var.project}-*",
      ]
    },
    {
      # Read the registry (what was registered, in what state). Registering is the PIPELINE's job (execution role);
      # approving is the approve role's job. This role does neither.
      Sid      = "ReadTheRegistry"
      Effect   = "Allow"
      Action   = ["sagemaker:DescribeModelPackage", "sagemaker:DescribeModelPackageGroup", "sagemaker:ListModelPackages"]
      Resource = local.ml_group_arns
    },
    {
      # The pipelines and the backfill wear the SageMaker execution role. Handing it over needs PassRole -- for that ONE
      # role, to SageMaker.
      Sid       = "PassTheExecutionRoleToSageMaker"
      Effect    = "Allow"
      Action    = ["iam:PassRole"]
      Resource  = "${local.arn_role}/${local.sagemaker_role_name}"
      Condition = { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } }
    },
    {
      # `mlops.py mlflow-url` opens the MLflow UI. The app's ARN ends in an id AWS chooses: see policy_parts.tf.
      Sid      = "OpenTheMlflowUi"
      Effect   = "Allow"
      Action   = ["sagemaker:CreatePresignedMlflowAppUrl", "sagemaker:DescribeMlflowApp"]
      Resource = local.mlflow_app_arn_pattern
    },
    {
      # The pipeline uploads training data; the JOBS (their own role) write datasets/, models/, metrics/, monitoring/.
      Sid      = "UploadTrainingData"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
      Resource = "${local.arn_s3}${local.ml_bucket}/data/*"
    },
    {
      Sid    = "ReadWhatThePipelinesWrote"
      Effect = "Allow"
      Action = ["s3:GetObject"]
      Resource = [
        "${local.arn_s3}${local.ml_bucket}/models/*",
        "${local.arn_s3}${local.ml_bucket}/datasets/*",
        "${local.arn_s3}${local.ml_bucket}/monitoring/*",
        "${local.arn_s3}${local.ml_bucket}/raw/*/backfill_report.json", # the report only, never the 493 MB CSV
      ]
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
      # "Which of the three prod model alarms is firing?" -- the answer to a drift-triggered run. Names only: this action
      # lists no secrets, and it is limited to the alarms of this course's prod model.
      Sid      = "ReadTheProdModelAlarms"
      Effect   = "Allow"
      Action   = ["cloudwatch:DescribeAlarms"]
      Resource = "${local.arn_cw}:alarm:${var.project}-prod-model-*"
    },
    {
      # Read the jobs' logs when one fails.
      Sid    = "ReadJobLogs"
      Effect = "Allow"
      Action = ["logs:DescribeLogStreams", "logs:GetLogEvents"]
      Resource = [
        "${local.arn_logs}:/aws/sagemaker/TrainingJobs", "${local.arn_logs}:/aws/sagemaker/TrainingJobs:*",
        "${local.arn_logs}:/aws/sagemaker/ProcessingJobs", "${local.arn_logs}:/aws/sagemaker/ProcessingJobs:*",
      ]
    },
  ]

  ml_approve_statements = [
    {
      # UpdateModelPackage is also how a version's MODEL CARD status moves (Draft -> Approved): the card is part of the package.
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
        # Put one model version on the endpoint of THIS environment. Every name starts finrisk-<env>-fraud:
        # the endpoint is exactly that, its configs and models carry -v<N>-<timestamp> after it.
        Sid    = "ManageThisEnvironmentsModelAndConfigs"
        Effect = "Allow"
        Action = [
          "sagemaker:CreateModel", "sagemaker:DeleteModel", "sagemaker:DescribeModel",
          "sagemaker:CreateEndpointConfig", "sagemaker:DeleteEndpointConfig", "sagemaker:DescribeEndpointConfig",
          "sagemaker:AddTags",
        ]
        Resource = [
          "${local.arn_sm}:model/${var.project}-${e}-fraud-*",
          "${local.arn_sm}:endpoint-config/${var.project}-${e}-fraud-*",
        ]
      },
      {
        # After a deploy, promote deletes this environment's configs and models older than the two newest (the rollback
        # target stays). It FINDS them with ListEndpointConfigs / ListModels, which AWS does not let a policy limit to named
        # resources (Resource must be "*"); they only list names. The deletes stay limited to finrisk-<env>-fraud-* above.
        # The first live promote was refused here, after the endpoint, the smoke test and the pointer had succeeded
        # (21 Oct 2026).
        Sid      = "FindThisEnvironmentsOldConfigsAndModels"
        Effect   = "Allow"
        Action   = ["sagemaker:ListEndpointConfigs", "sagemaker:ListModels"]
        Resource = "*"
      },
      {
        # CreateEndpoint / UpdateEndpoint name the endpoint AND the config; InvokeEndpoint is the smoke test.
        Sid    = "ManageAndSmokeTestThisEnvironmentsEndpoint"
        Effect = "Allow"
        Action = [
          "sagemaker:CreateEndpoint", "sagemaker:UpdateEndpoint", "sagemaker:DescribeEndpoint", "sagemaker:DeleteEndpoint",
          "sagemaker:InvokeEndpoint", "sagemaker:AddTags",
        ]
        Resource = [
          "${local.arn_sm}:endpoint/${var.project}-${e}-fraud",
          "${local.arn_sm}:endpoint-config/${var.project}-${e}-fraud-*",
        ]
      },
      {
        # The endpoint wears finrisk-<env>-endpoint (made by envs/). This role may hand over that ONE role, to SageMaker.
        Sid       = "PassTheEndpointRoleOfThisEnvironment"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = "${local.arn_role}/${var.project}-${e}-endpoint"
        Condition = { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } }
      },
      {
        # A blue/green update with auto-rollback makes SageMaker check the alarms with the CALLER's permission. Only this
        # environment's guardrail alarms (pre-prod and prod have them; dev and sit have none, which is fine).
        Sid      = "ReadThisEnvironmentsGuardrailAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = "${local.arn_cw}:alarm:${var.project}-${e}-endpoint-*"
      },
      {
        # The pointer the service reads. This is the whole "go live" of a model: one parameter, written AFTER the endpoint is InService.
        Sid      = "ReadAndMoveTheModelPointer"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "${local.arn_ssm}/${var.project}/${e}/model"
      },
      {
        Sid      = "ReadTheServiceUrlAndTheEndpointRole"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = ["${local.arn_ssm}/${var.project}/${e}/app_url", "${local.arn_ssm}/${var.project}/${e}/endpoint_role_arn"]
      },
      {
        # Names that are the same everywhere (ML bucket, model group, ...): the SHARED family, read-only.
        Sid      = "ReadSharedNames"
        Effect   = "Allow"
        Action   = local.ssm_read_actions
        Resource = "${local.arn_ssm}/${var.project}/shared/*"
      },
    ]
  }

  # The simulated outside world (finrisk-ml replay.yml): customers send traffic THROUGH THE APP (so it needs the app's URL, and
  # no direct access to any endpoint), the analysts' labels arrive in S3, the transactions' features are recorded in the
  # Feature Store. No models/, no pointers, no registry: it can generate evidence but cannot change what is deployed.
  ml_feedback_statements = [
    {
      Sid      = "ReadTheReplaySet"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${local.arn_s3}${local.ml_bucket}/replay/*"
    },
    {
      Sid      = "WriteFeedbackLabels"
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
      Resource = "${local.arn_s3}${local.ml_bucket}/labels/source=feedback/*"
    },
    {
      # Listing is how the replay finds the day folders. Names only, and only under the two prefixes it uses.
      Sid       = "ListTheReplayAndFeedbackFolders"
      Effect    = "Allow"
      Action    = ["s3:ListBucket"]
      Resource  = "${local.arn_s3}${local.ml_bucket}"
      Condition = { StringLike = { "s3:prefix" = ["replay/*", "replay/", "labels/source=feedback/*", "labels/source=feedback/"] } }
    },
    {
      Sid      = "FindTheBucketRegion"
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation"]
      Resource = "${local.arn_s3}${local.ml_bucket}"
    },
    {
      Sid      = "RecordFeaturesInTheFeatureStore"
      Effect   = "Allow"
      Action   = ["sagemaker:BatchWriteRecord", "sagemaker:PutRecord", "sagemaker:DescribeFeatureGroup"]
      Resource = local.feature_group_arn
    },
    {
      Sid      = "ReadTheProdUrlAndSharedNames"
      Effect   = "Allow"
      Action   = local.ssm_read_actions
      Resource = ["${local.arn_ssm}/${var.project}/prod/app_url", "${local.arn_ssm}/${var.project}/shared/*"]
    },
  ]

  ml_roles = merge(
    {
      "${var.project}-ml-train" = {
        repo        = "ml"
        subject     = "environment:ml"
        description = "finrisk-ml environment ml: build the training image, create and start the SageMaker pipelines, run the backfill."
        statements  = local.ml_train_statements
      }
      "${var.project}-ml-approve" = {
        repo        = "ml"
        subject     = "environment:model-approval"
        description = "finrisk-ml environment model-approval (reviewer): change a model version's approval status. Nothing else."
        statements  = local.ml_approve_statements
      }
      "${var.project}-ml-feedback" = {
        repo        = "ml"
        subject     = "environment:simulation"
        description = "finrisk-ml environment simulation: replay days 18-30 through the app, write feedback labels, record features. Nothing near models or pointers."
        statements  = local.ml_feedback_statements
      }
    },
    {
      for e in local.environments : "${var.project}-ml-promote-${e}" => {
        repo        = "ml"
        subject     = "environment:${e}"
        description = "finrisk-ml environment ${e}: put a model version on the ${e} endpoint and move /finrisk/${e}/model. Nothing else."
        statements  = local.ml_promote_statements[e]
      }
    },
  )
}

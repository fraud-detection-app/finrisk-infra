# Roles of the finrisk-knowledge repository (the RAG knowledge base).
#
#   role                       who may become it                                      what it may do
#   finrisk-kb-build           ...finrisk-knowledge:ref:refs/heads/main               write indexes/<version>/ to the KB bucket, embed with Titan
#   finrisk-kb-promote-<env>   ...finrisk-knowledge:environment:<env>   (x4)          write the index pointer of ONE environment

locals {
  kb_build_statements = [
    {
      Sid      = "ReadAndWriteIndexes"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
      Resource = "${local.arn_s3}${local.kb_bucket}/indexes/*"
    },
    {
      # Listing is how the incremental build finds "the latest published index". Names only.
      Sid       = "ListIndexes"
      Effect    = "Allow"
      Action    = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource  = "${local.arn_s3}${local.kb_bucket}"
      Condition = { StringLike = { "s3:prefix" = ["indexes/*", "indexes/"] } }
    },
    {
      # One foundation model, in this Region: the embedding model. (Cross-Region profiles are a different ARN.)
      Sid      = "EmbedWithTitan"
      Effect   = "Allow"
      Action   = ["bedrock:InvokeModel"]
      Resource = "arn:aws:bedrock:${local.region}::foundation-model/${var.embedding_model_id}"
    },
    {
      # The evaluation gate compares with the index prod uses today.
      Sid      = "ReadTheProdIndexPointer"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "${local.arn_ssm}/${var.project}/prod/index"
    },
  ]

  kb_promote_statements = {
    for e in local.environments : e => [
      {
        Sid      = "ReadTheIndex"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${local.arn_s3}${local.kb_bucket}/indexes/*"
      },
      {
        Sid       = "ListIndexes"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = "${local.arn_s3}${local.kb_bucket}"
        Condition = { StringLike = { "s3:prefix" = ["indexes/*", "indexes/"] } }
      },
      {
        Sid      = "ReadAndMoveTheIndexPointer"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "${local.arn_ssm}/${var.project}/${e}/index"
      },
      {
        Sid      = "ReadTheServiceUrl"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "${local.arn_ssm}/${var.project}/${e}/app_url"
      },
    ]
  }

  kb_roles = merge(
    {
      "${var.project}-kb-build" = {
        repo        = "knowledge"
        subject     = "ref:refs/heads/main"
        description = "finrisk-knowledge main branch: build an index, write it to the KB bucket, embed with Titan."
        statements  = local.kb_build_statements
      }
    },
    {
      for e in local.environments : "${var.project}-kb-promote-${e}" => {
        repo        = "knowledge"
        subject     = "environment:${e}"
        description = "finrisk-knowledge environment ${e}: point ${e} at an index version (/finrisk/${e}/index). Nothing else."
        statements  = local.kb_promote_statements[e]
      }
    },
  )
}

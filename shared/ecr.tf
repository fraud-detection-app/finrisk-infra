# Two container registries. The service image is built ONCE per merge and promoted dev -> sit -> pre-prod -> prod by
# digest; the training image (finrisk-ml) starts FROM a pinned service image and adds the training script.

locals {
  repositories = {
    app   = "${var.project}-app"   # service image, tags sha-<finrisk-app sha>
    train = "${var.project}-train" # training image, tags sha-<finrisk-ml sha>
  }
}

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name = each.value

  # IMMUTABLE: a tag can never be pushed twice. "sha-1a2b3c..." means one image forever, so what passed sit is what
  # reaches prod. (We deploy by digest anyway; this stops accidents.)
  image_tag_mutability = "IMMUTABLE"

  # Images are rebuilt from source, so destroy may delete them. (The buckets below are different.)
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true # a free vulnerability scan every time an image is pushed
  }
}

# Keep the last N images; ECR deletes older ones. N must be larger than the number of releases you might roll back
# through -- a digest deleted from here can no longer be deployed.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = local.repositories

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last ${var.keep_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_images
      }
      action = { type = "expire" }
    }]
  })
}

# Lambda pulls the image with ITS OWN service identity, not with the deployer's. For that the repository itself must
# say "Lambda may read these images" (AWS docs: ECR repository policy for Lambda). If the statement is missing, Lambda
# tries to add it, but only a caller who may call ecr:SetRepositoryPolicy can let it. The deploy roles in finrisk-app
# may not (we keep them narrow), so we write the statement here, once, with the role that owns the repository.
# Only the app repository: the training image is pulled by SageMaker with its role, and ECS tasks by their execution role.
resource "aws_ecr_repository_policy" "lambda_pull" {
  repository = aws_ecr_repository.this["app"].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LambdaPullForFinriskFunctions"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      # Only functions named finrisk-* in this account and Region (not every Lambda function that could be pointed here).
      Condition = {
        StringLike = { "aws:sourceArn" = "arn:aws:lambda:${local.region}:${local.acct}:function:${var.project}-*" }
      }
    }]
  })
}

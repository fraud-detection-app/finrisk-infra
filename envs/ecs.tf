# pre-prod and prod run the container on ECS Express Mode -- Fargate behind a load balancer with HTTPS, always warm
# (no cold start). The SERVICE itself is created by finrisk-app. What this repository owns are the two roles Express
# Mode needs besides the app's runtime role (iam.tf), because roles are infrastructure:
#
#   execution role      lets ECS pull the image from ECR and write container logs
#   infrastructure role lets ECS build the load balancer, security groups and scaling for us
#
# Both are AWS managed policies; the trust policies are the ones in the Express Mode CLI guide
# (docs.aws.amazon.com/AmazonECS/latest/developerguide/express-service-getting-started.html).
# They exist only when compute = "ecs" (count = 0 otherwise).

locals {
  use_ecs = var.compute == "ecs"
}

resource "aws_iam_role" "ecs_execution" {
  count = local.use_ecs ? 1 : 0

  name = "${local.name}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  depends_on = [terraform_data.workspace_matches_env]
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  count = local.use_ecs ? 1 : 0

  role       = aws_iam_role.ecs_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_infrastructure" {
  count = local.use_ecs ? 1 : 0

  name = "${local.name}-ecs-infrastructure"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  depends_on = [terraform_data.workspace_matches_env]
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  count = local.use_ecs ? 1 : 0

  role       = aws_iam_role.ecs_infrastructure[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
}

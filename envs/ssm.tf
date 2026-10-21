# /finrisk/<env>/*: what the other pipelines need to know about this environment, in Parameter Store.
# Plain `String` parameters: none is a secret. The names are a contract with finrisk-app, finrisk-ml and
# finrisk-knowledge -- do not rename one without them.

locals {
  # Written by this stack, never changed by anyone else.
  env_parameters = merge(
    {
      runtime_role_arn = aws_iam_role.runtime.arn
      log_group        = aws_cloudwatch_log_group.app.name
      bucket           = aws_s3_bucket.env.bucket

      # The role this environment's model endpoint wears. finrisk-ml reads it to create the endpoint (and may pass only this one).
      endpoint_role_arn = aws_iam_role.endpoint.arn
    },
    local.use_ecs ? {
      ecs_execution_role_arn      = aws_iam_role.ecs_execution[0].arn
      ecs_infrastructure_role_arn = aws_iam_role.ecs_infrastructure[0].arn
    } : {},
  )
}

resource "aws_ssm_parameter" "env" {
  for_each = local.env_parameters

  name        = "/${var.project}/${var.env}/${each.key}"
  type        = "String"
  value       = each.value
  description = "Published by finrisk-infra/envs for ${var.env}. Read by the other pipelines."
}

# ---------------------------------------------------------------- the two POINTERS
# /finrisk/<env>/model  and  /finrisk/<env>/index  say WHICH model version and WHICH knowledge-base index this
# environment serves. The service reads them (every minute or so) and hot-reloads when they change.
#
# This stack CREATES them -- with the empty value {"version": null}, "nothing promoted yet" -- and then lets go:
#
#   lifecycle { ignore_changes = [value] }
#
# From then on the pointers are OWNED by the pipelines: finrisk-ml writes /model, finrisk-knowledge writes /index.
# Without ignore_changes, the next `terraform apply` here would reset a promoted pointer back to "null" and silently
# roll the environment back to the baked fallback. The same words in the plan tell you it is working: this stack
# never shows a change on these two, whatever the pipelines did.
#
#   /model = {"version": <int>, "serving": "endpoint", "endpoint": "finrisk-<env>-fraud", "endpoint_config": "...", "model_package_arn": "arn:...",
#             "status": "Approved", "promoted_at": "<iso>", "run": "<url>"}      ({"version": null} = serve the baked model in process)
#   /index = {"version": "<YYYYMMDD-HHMMSS>-<sha7>", "uri": "s3://.../indexes/<v>/", "embeddings": "titan|tfidf", "docs": <n>, "chunks": <n>, "promoted_at": "<iso>", "run": "<url>"}
resource "aws_ssm_parameter" "model_pointer" {
  name        = "/${var.project}/${var.env}/model"
  type        = "String"
  value       = var.pointer_seed
  description = "Which model version ${var.env} serves. Created by finrisk-infra/envs; OWNED by finrisk-ml after that."

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "index_pointer" {
  name        = "/${var.project}/${var.env}/index"
  type        = "String"
  value       = var.pointer_seed
  description = "Which knowledge-base index ${var.env} serves. Created by finrisk-infra/envs; OWNED by finrisk-knowledge after that."

  lifecycle {
    ignore_changes = [value]
  }
}

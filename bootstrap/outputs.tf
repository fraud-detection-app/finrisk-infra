# Outputs print after `terraform apply` -- and any time with `terraform output`.
# scripts/github_bootstrap.sh reads `terraform output -json` and turns it into `gh variable set`, `gh secret set`
# and Environment calls for ALL FOUR repositories.
#
# Why SECRETS for the ARNs and bucket names? The repositories are public, so their Actions logs are world-readable, and
# every one of these values contains the 12-digit AWS account id. GitHub hides a secret's value everywhere in a log
# (including the `env:` lines it prints above each step); it does not hide a variable's. The account id is not a
# password and a role ARN alone grants nothing without the OIDC trust -- the secret is only there to keep the id out
# of a public log. The outputs that hold an id are marked `sensitive`, so `terraform apply` does not print them on a
# shared screen either. (`terraform output -json` does print them: the script needs them.)

locals {
  role_arn = { for name, r in aws_iam_role.this : name => r.arn }

  # GitHub Environments per repository: Environment -> the role it uses. ONE naming rule for all four repositories:
  #   a job WITH `environment:` reads secrets.AWS_ROLE_ARN -- an ENVIRONMENT secret holding that Environment's role;
  #   a job WITHOUT an environment (a pull-request plan, a build on main) reads a REPOSITORY secret named after its role
  #   (AWS_PLAN_ROLE_ARN, AWS_DRIFT_ROLE_ARN, AWS_BUILD_ROLE_ARN, AWS_KB_BUILD_ROLE_ARN).
  # infra:  infra-shared, infra-dev, infra-sit, infra-pre-prod, infra-prod
  # app, knowledge:  dev, sit, pre-prod, prod
  # ml:  ml (train), model-approval (approve), dev, sit, pre-prod, prod (promote), simulation (feedback: replay + labels; no reviewer)
  environment_role = {
    infra = merge(
      { "infra-shared" = "${var.project}-infra-apply-shared" },
      { for e in local.environments : "infra-${e}" => "${var.project}-infra-apply-${e}" },
    )
    app = { for e in local.environments : e => "${var.project}-app-deploy-${e}" }
    ml = merge(
      { "ml" = "${var.project}-ml-train", "model-approval" = "${var.project}-ml-approve", "simulation" = "${var.project}-ml-feedback" },
      { for e in local.environments : e => "${var.project}-ml-promote-${e}" },
    )
    knowledge = { for e in local.environments : e => "${var.project}-kb-promote-${e}" }
  }

  # Repository VARIABLES (no account id in them).
  repo_variables = {
    infra     = { AWS_REGION = local.region }
    app       = { AWS_REGION = local.region }
    ml        = { AWS_REGION = local.region }
    knowledge = { AWS_REGION = local.region }
  }

  # Repository SECRETS (each value contains the account id).
  repo_secrets = {
    infra = {
      TF_STATE_BUCKET    = local.state_bucket
      AWS_PLAN_ROLE_ARN  = local.role_arn["${var.project}-infra-plan"]
      AWS_DRIFT_ROLE_ARN = local.role_arn["${var.project}-infra-drift"]
    }
    app = {
      TF_STATE_BUCKET    = local.state_bucket
      AWS_BUILD_ROLE_ARN = local.role_arn["${var.project}-app-build"]
      ECR_REPOSITORY     = "${local.ecr_host}/${local.ecr_app}"
    }
    # finrisk-ml needs none: it reads the ML bucket, the SageMaker role and the model group from SSM (/finrisk/shared/*),
    # and its only secret is the Environment secret AWS_ROLE_ARN.
    ml = {}
    knowledge = {
      KB_BUCKET             = local.kb_bucket
      AWS_KB_BUILD_ROLE_ARN = local.role_arn["${var.project}-kb-build"]
    }
  }
}

output "github_org" {
  description = "The organisation the roles trust. scripts/github_bootstrap.sh checks it against the one you configure."
  value       = var.github_org
}

output "repositories" {
  description = "Repository key (infra, app, ml, knowledge) -> repository name."
  value       = var.repos
}

output "trusted_sub_prefixes" {
  description = "Repository key -> the first part of the sub claim every role of that repository trusts (immutable form with numeric ids, or classic). Compare it with what GitHub reports: bash scripts/oidc_subjects.sh <org>."
  value       = local.sub_prefix
}

output "aws_region" {
  description = "The Region everything lives in."
  value       = local.region
}

output "state_bucket" {
  description = "The bucket holding Terraform's state. Contains the account id."
  sensitive   = true
  value       = local.state_bucket
}

output "oidc_provider_arn" {
  description = "The GitHub identity provider (token.actions.githubusercontent.com). Contains the account id."
  sensitive   = true
  value       = local.oidc_provider_arn
}

output "role_arns" {
  description = "Role name -> ARN, for every role in the table (roles_*.tf). Contains the account id."
  sensitive   = true
  value       = local.role_arn
}

output "github_repo_variables" {
  description = "Repository key -> { NAME = value } for `gh variable set`. No account id in any of them."
  value       = local.repo_variables
}

output "github_repo_secrets" {
  description = "Repository key -> { NAME = value } for `gh secret set`. Each value contains the account id."
  sensitive   = true
  value       = local.repo_secrets
}

output "github_environments" {
  description = "Repository key -> list of GitHub Environment names that repository uses."
  value       = { for repo, envs in local.environment_role : repo => sort(keys(envs)) }
}

output "github_environment_secrets" {
  description = "Repository key -> Environment name -> { AWS_ROLE_ARN = role ARN }: each Environment has its own role."
  sensitive   = true
  value = {
    for repo, envs in local.environment_role : repo => {
      for env, role in envs : env => { AWS_ROLE_ARN = local.role_arn[role] }
    }
  }
}

# bootstrap/oidc.tf -- how GitHub Actions gets into AWS WITHOUT any stored key, for all four repositories.
#
# The old way: create an IAM user, make an access key, paste it into GitHub as a secret. That key lives for years,
# can be copied, and leaks in logs. The new way is OIDC (OpenID Connect):
#
#   1. Every GitHub Actions job can ask GitHub for a short-lived signed token ("I am repo X, branch Y, environment Z").
#      The token lives minutes, and only that job sees it.
#   2. AWS is told once (the provider below) "trust tokens signed by token.actions.githubusercontent.com".
#   3. Each role says WHICH tokens may become it. The rule is a condition on the token's `sub` (subject) claim, and it
#      is an EXACT match -- one repository, one branch or one environment. There is no wildcard anywhere in this file.
#      A sub is two parts glued with a colon: a PREFIX that names the repository, and a SUFFIX that names the job:
#
#        finrisk-app-build           sub = <prefix of finrisk-app>:ref:refs/heads/main
#        finrisk-app-deploy-prod     sub = <prefix of finrisk-app>:environment:prod
#        finrisk-infra-plan          sub = <prefix of finrisk-infra>:pull_request
#
#      A job that uses `environment: prod` gets the suffix "environment:prod". GitHub only starts such a job from
#      main and (pre-prod, prod) only after the reviewer approves, so the prod role is reachable only through that gate.
#      A repository can never use another repository's roles: the repository is part of the prefix.
#
# ---------------------------------------------------------------- why the prefix is read from GitHub
# Since 15 July 2026 every NEW repository gets an IMMUTABLE subject, and there is no switch to turn it off. The prefix then
# carries two numbers, the id of the organisation and the id of the repository:
#
#        classic    repo:fraud-detection-app/finrisk-infra
#        immutable  repo:fraud-detection-app@343247080/finrisk-infra@1422750317
#
# Why GitHub did it: a name can be reused. Delete a repository (or rename the organisation), and an attacker can create one
# with the same name and inherit every cloud trust that was written with the NAME. The numeric ids are never reused, so a
# trust written with them still points at the repository you meant, and only at that one.
#
# We keep the EXACT match (no `repo:org/*`, no StringLike), so the numbers have to be in the trust policy, and they are not
# known until the repository exists. So the order is: create the four empty repositories first, ask GitHub for their prefixes
# (scripts/oidc_subjects.sh writes oidc_subjects.auto.tfvars.json, which fills var.sub_prefixes), then apply this folder.
# Where a key is missing from var.sub_prefixes the classic `repo:<org>/<name>` is used (a repository created before the
# change). If you delete and re-create a repository, its id changes: run the script again and apply again.
#
# Roles are defined in roles_infra.tf, roles_app.tf, roles_ml.tf, roles_kb.tf as ONE table (local.roles); this file
# turns each row into a role with a trust policy and an inline policy (for_each), so adding a role is adding a row.
#
# ---------------------------------------------------------------- what is BROAD, and why
# Everything is least privilege by NAME (finrisk-<env>-*, /finrisk/<env>/*, one bucket, one repository, one function)
# where AWS lets us name the resource. These are the exceptions. Read them: a role is only as safe as its widest line.
#
#   all roles    - no key, no password, a session of one hour at most; the token is valid for one job.
#   ecr login    - `ecr:GetAuthorizationToken` on "*" (app-build, ml-train): AWS has no resource for "log in to ECR".
#   read-only    - "*" for Describe/List calls that return names or settings and cannot change anything: ec2, elasticloadbalancing,
#   refresh        application-autoscaling, ecs Describe/List, logs:DescribeLogGroups, ssm:DescribeParameters. Terraform's
#                  refresh makes them; they have no resource to name.
#   s3 Get*/List* - on the bucket itself (not its files) of plan, apply-* and the Terraform refresh reads a dozen bucket
#                  settings; naming each one is a whack-a-mole. Files in the bucket are NOT readable through it.
#   apply-<env>  - can create, change and delete IAM roles named finrisk-<env>-* and write their inline policies. A role
#                  that edits the policy of the roles it creates could, in principle, give them more than they should
#                  have. The guard: only CODE ON main (reviewed in a PR, then deployed through the Environment, with a
#                  reviewer on shared, pre-prod and prod) ever runs with this role. AttachRolePolicy is limited to the
#                  two AWS-managed policies ECS Express needs.
#   apply-shared - same idea for FIVE role names (see below).
#                - also ecr:SetRepositoryPolicy/DeleteRepositoryPolicy on the two repositories: the policy that lets Lambda pull finrisk-app.
#   app-deploy   - `lambda:*` but ONLY on the function finrisk-<env> (actions broad, resource exact).
#                - ECS Express Mode: services are named (service/*/finrisk-<env>), but the cluster and task-definition names
#                  are chosen by AWS, so those two are `cluster/*` and `task-definition/*`.
#                - iam:PassRole only for finrisk-<env>-* roles and only to lambda / ecs-tasks / ecs.
#   plan, drift  - can read every state object of the infra stacks. State holds no secret in this course; if yours does,
#                  tighten this first. A pull request (from this repository, never a fork) can change the workflow, so
#                  treat "can open a PR" as "can read the plan role's data". It cannot write anything.
#   ml-train     - the one role that starts the SageMaker pipelines (finrisk-train, finrisk-monitor) and the backfill job, and the
#                  one that hands the SageMaker execution role over (PassRole, one role, only to sagemaker). Since week 13b it
#                  does NOT create training jobs or register models itself: the pipeline does, wearing the execution role. It
#                  can start a run but NOT approve a model: that is finrisk-ml-approve, behind its own Environment with a reviewer.
#                - `sagemaker:CreatePresignedMlflowAppUrl` on mlflow-app/*: the app's ARN ends in an id AWS chooses, so it can
#                  only be named by a pattern (one MLflow App per account).
#   ml-promote   - one per environment: CreateModel / CreateEndpointConfig / CreateEndpoint / UpdateEndpoint on names that start
#                  finrisk-<env>-fraud, PassRole only for finrisk-<env>-endpoint, DescribeAlarms only for finrisk-<env>-endpoint-*.
#   ml-feedback  - the simulated outside world: reads replay/*, writes labels/source=feedback/*, records features in the Feature
#                  Store. It has no access to models/, to any endpoint, to the registry or to any pointer.
#   apply-shared - five role names instead of one (sagemaker-exec, mlflow, studio, scheduler, events), PassRole for each to ITS
#                  service only; the Feature Store group, the Glue database finrisk_ml and the Athena workgroup finrisk by name.
#                - the Studio domain and user profile (`domain/*`, `user-profile/*`): their ids are chosen by AWS (d-xxxx), so
#                  they cannot be named before they exist. The MLflow App likewise (`mlflow-app/*`).
#   apply-<env>  - also CloudWatch alarms named finrisk-<env>-* (the endpoint guardrails and, in prod, the model alarms).
#   kb-build     - bedrock:InvokeModel for ONE foundation model (Titan embeddings) in this Region.
#
# Not here, on purpose: iam:CreateServiceLinkedRole. The three service-linked roles ECS Express Mode needs are created
# ONCE by hand (see main.tf), so no pipeline role can create roles for AWS services.

locals {
  github_host = "token.actions.githubusercontent.com"

  # An OIDC provider's ARN is always built this way, so the roles do not have to wait for the resource below to be
  # read back (the depends_on on each role still makes them wait for it to exist).
  oidc_provider_arn = "arn:aws:iam::${local.acct}:oidc-provider/${local.github_host}"

  # The whole table: role name -> { repo, subject, description, statements }.
  roles = merge(local.infra_roles, local.app_roles, local.ml_roles, local.kb_roles)

  # The first part of each repository's sub: what GitHub reported (var.sub_prefixes), or the classic form when none was given.
  sub_prefix = { for key, name in var.repos : key => lookup(var.sub_prefixes, key, "repo:${var.github_org}/${name}") }

  # The trust policy: "a token from GitHub, meant for AWS (aud), whose sub is EXACTLY this repository's prefix + this subject".
  trust_policy = {
    for name, r in local.roles : name => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = { Federated = local.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.github_host}:aud" = "sts.amazonaws.com"
            "${local.github_host}:sub" = "${local.sub_prefix[r.repo]}:${r.subject}"
          }
        }
      }]
    })
  }
}

# ---------------------------------------------------------------- the identity provider
# No thumbprint_list: since 2023 AWS validates GitHub's certificate chain with its own library of trusted root CAs, so
# the provider (6.x) leaves the list optional. The `aud` check lives in each role's trust policy.
# One per account: if week 13a's practice repo (or anything else) already made it, set create_oidc_provider = false.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.github_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# ---------------------------------------------------------------- the roles
resource "aws_iam_role" "this" {
  for_each = toset(keys(local.roles))

  name               = each.key
  description        = local.roles[each.key].description
  assume_role_policy = local.trust_policy[each.key]

  max_session_duration = 3600

  depends_on = [aws_iam_openid_connect_provider.github]
}

resource "aws_iam_role_policy" "this" {
  for_each = toset(keys(local.roles))

  name = each.key
  role = aws_iam_role.this[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.roles[each.key].statements
  })
}

# Offline test of the GitHub OIDC roles (oidc.tf, roles_*.tf). No AWS account is touched: mock_provider fakes the
# AWS provider, so `terraform test` costs nothing and needs no credentials.
#
#   bash scripts/tf_checks.sh bootstrap
#
# What it proves: the role table is exactly the one in the course contract; every role trusts ONE repository and
# ONE subject (deploy/promote roles: their own Environment; build roles: main only; plan: pull requests only);
# no wildcard anywhere; the plan role cannot change anything; no role is bigger than IAM allows.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-2"
    }
  }
}

variables {
  github_org = "acme-lab"
}

# ------------------------------------------------------------------ who may become which role
run "there_are_exactly_the_roles_of_the_contract" {
  command = plan

  assert {
    condition = toset(keys(aws_iam_role.this)) == toset([
      "finrisk-infra-plan", "finrisk-infra-drift", "finrisk-infra-apply-shared",
      "finrisk-infra-apply-dev", "finrisk-infra-apply-sit", "finrisk-infra-apply-pre-prod", "finrisk-infra-apply-prod",
      "finrisk-app-build",
      "finrisk-app-deploy-dev", "finrisk-app-deploy-sit", "finrisk-app-deploy-pre-prod", "finrisk-app-deploy-prod",
      "finrisk-ml-train", "finrisk-ml-approve", "finrisk-ml-feedback",
      "finrisk-ml-promote-dev", "finrisk-ml-promote-sit", "finrisk-ml-promote-pre-prod", "finrisk-ml-promote-prod",
      "finrisk-kb-build",
      "finrisk-kb-promote-dev", "finrisk-kb-promote-sit", "finrisk-kb-promote-pre-prod", "finrisk-kb-promote-prod",
    ])
    error_message = "The role table drifted from the contract (spec 3.2)."
  }

  assert {
    condition     = length(aws_iam_role.this) == 24 && length(aws_iam_role_policy.this) == 24
    error_message = "24 roles and 24 inline policies (week 13b added finrisk-ml-feedback)."
  }

  assert {
    condition     = alltrue([for name, r in aws_iam_role.this : r.name == name])
    error_message = "A role's name must be its table key."
  }
}

run "each_role_trusts_exactly_one_subject_of_exactly_one_repository" {
  command = plan

  # role -> the sub the token must carry. Spelled out here on purpose: this table IS the contract.
  assert {
    condition = alltrue([
      for name, sub in {
        "finrisk-infra-plan"           = "repo:acme-lab/finrisk-infra:pull_request"
        "finrisk-infra-drift"          = "repo:acme-lab/finrisk-infra:ref:refs/heads/main"
        "finrisk-infra-apply-shared"   = "repo:acme-lab/finrisk-infra:environment:infra-shared"
        "finrisk-infra-apply-dev"      = "repo:acme-lab/finrisk-infra:environment:infra-dev"
        "finrisk-infra-apply-sit"      = "repo:acme-lab/finrisk-infra:environment:infra-sit"
        "finrisk-infra-apply-pre-prod" = "repo:acme-lab/finrisk-infra:environment:infra-pre-prod"
        "finrisk-infra-apply-prod"     = "repo:acme-lab/finrisk-infra:environment:infra-prod"
        "finrisk-app-build"            = "repo:acme-lab/finrisk-app:ref:refs/heads/main"
        "finrisk-app-deploy-dev"       = "repo:acme-lab/finrisk-app:environment:dev"
        "finrisk-app-deploy-sit"       = "repo:acme-lab/finrisk-app:environment:sit"
        "finrisk-app-deploy-pre-prod"  = "repo:acme-lab/finrisk-app:environment:pre-prod"
        "finrisk-app-deploy-prod"      = "repo:acme-lab/finrisk-app:environment:prod"
        "finrisk-ml-train"             = "repo:acme-lab/finrisk-ml:environment:ml"
        "finrisk-ml-approve"           = "repo:acme-lab/finrisk-ml:environment:model-approval"
        "finrisk-ml-feedback"          = "repo:acme-lab/finrisk-ml:environment:simulation"
        "finrisk-ml-promote-dev"       = "repo:acme-lab/finrisk-ml:environment:dev"
        "finrisk-ml-promote-sit"       = "repo:acme-lab/finrisk-ml:environment:sit"
        "finrisk-ml-promote-pre-prod"  = "repo:acme-lab/finrisk-ml:environment:pre-prod"
        "finrisk-ml-promote-prod"      = "repo:acme-lab/finrisk-ml:environment:prod"
        "finrisk-kb-build"             = "repo:acme-lab/finrisk-knowledge:ref:refs/heads/main"
        "finrisk-kb-promote-dev"       = "repo:acme-lab/finrisk-knowledge:environment:dev"
        "finrisk-kb-promote-sit"       = "repo:acme-lab/finrisk-knowledge:environment:sit"
        "finrisk-kb-promote-pre-prod"  = "repo:acme-lab/finrisk-knowledge:environment:pre-prod"
        "finrisk-kb-promote-prod"      = "repo:acme-lab/finrisk-knowledge:environment:prod"
      } :
      jsondecode(aws_iam_role.this[name].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == sub
    ])
    error_message = "A role trusts the wrong subject. Every deploy/promote role must name its own repository AND its own Environment."
  }

  assert {
    condition = alltrue([
      for name, r in aws_iam_role.this :
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    ])
    error_message = "Every role must require the audience sts.amazonaws.com."
  }

  # Exact matches only: one condition operator, one sub (a string, not a list), no pattern characters.
  assert {
    condition = alltrue([
      for name, r in aws_iam_role.this :
      keys(jsondecode(r.assume_role_policy).Statement[0].Condition) == ["StringEquals"] &&
      length(jsondecode(r.assume_role_policy).Statement) == 1 &&
      !strcontains(r.assume_role_policy, "*") && !strcontains(r.assume_role_policy, "?") &&
      can(regex("^repo:[^:*?]+/[^:*?]+:", jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]))
    ])
    error_message = "Trust policies must be a single StringEquals on a single sub, without wildcards."
  }

  assert {
    condition = alltrue([
      for name, r in aws_iam_role.this :
      jsondecode(r.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(r.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    ])
    error_message = "Roles must be assumed with a web identity from the account's GitHub provider."
  }
}

run "build_roles_name_only_main_and_deploy_roles_name_an_environment_and_no_branch" {
  command = plan

  assert {
    condition = alltrue([
      for name in ["finrisk-app-build", "finrisk-kb-build", "finrisk-infra-drift"] :
      endswith(jsondecode(aws_iam_role.this[name].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], ":ref:refs/heads/main") &&
      !strcontains(aws_iam_role.this[name].assume_role_policy, "environment:") && !strcontains(aws_iam_role.this[name].assume_role_policy, "pull_request")
    ])
    error_message = "Build roles (and the drift role) trust the main branch and nothing else."
  }

  # Every role that changes a stack is reached through an Environment: no branch, no pull request.
  assert {
    condition = alltrue([
      for name, r in aws_iam_role.this :
      strcontains(r.assume_role_policy, ":environment:") || contains(["finrisk-app-build", "finrisk-kb-build", "finrisk-infra-drift", "finrisk-infra-plan"], name)
    ])
    error_message = "Only build, drift and plan roles may be reached without an Environment."
  }

  assert {
    condition     = !strcontains(aws_iam_role.this["finrisk-infra-plan"].assume_role_policy, "refs/heads") && !strcontains(aws_iam_role.this["finrisk-infra-plan"].assume_role_policy, "environment:")
    error_message = "The plan role is for pull requests only."
  }

  # prod must not be reachable as pre-prod, nor the other way round: the sub ends right after the name.
  assert {
    condition = alltrue([
      for prefix in ["finrisk-app-deploy", "finrisk-ml-promote", "finrisk-kb-promote"] :
      !strcontains(aws_iam_role.this["${prefix}-prod"].assume_role_policy, "pre-prod") && !strcontains(aws_iam_role.this["${prefix}-prod"].assume_role_policy, "environment:dev")
    ])
    error_message = "A prod role names another environment."
  }
}

run "only_this_organisation_and_these_repositories_are_trusted" {
  command = plan

  assert {
    condition = alltrue([
      for name, r in aws_iam_role.this :
      startswith(jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], "repo:acme-lab/finrisk-")
    ])
    error_message = "Every sub must start with repo:<org>/finrisk-."
  }
}

# ------------------------------------------------------------------ immutable subjects (repositories created after 15 July 2026)
# GitHub puts the numeric ids of the organisation and the repository into the prefix of the sub. The roles must carry
# EXACTLY that prefix (still one StringEquals, no wildcard), and still trust only their own repository.
run "with_immutable_prefixes_every_role_trusts_the_exact_immutable_sub_of_its_repository" {
  command = plan

  variables {
    sub_prefixes = {
      infra     = "repo:acme-lab@111/finrisk-infra@1001"
      app       = "repo:acme-lab@111/finrisk-app@1002"
      ml        = "repo:acme-lab@111/finrisk-ml@1003"
      knowledge = "repo:acme-lab@111/finrisk-knowledge@1004"
    }
  }

  # role -> the sub the token must carry. Spelled out on purpose: this table IS the contract.
  assert {
    condition = alltrue([
      for name, sub in {
        "finrisk-infra-plan"           = "repo:acme-lab@111/finrisk-infra@1001:pull_request"
        "finrisk-infra-drift"          = "repo:acme-lab@111/finrisk-infra@1001:ref:refs/heads/main"
        "finrisk-infra-apply-shared"   = "repo:acme-lab@111/finrisk-infra@1001:environment:infra-shared"
        "finrisk-infra-apply-dev"      = "repo:acme-lab@111/finrisk-infra@1001:environment:infra-dev"
        "finrisk-infra-apply-sit"      = "repo:acme-lab@111/finrisk-infra@1001:environment:infra-sit"
        "finrisk-infra-apply-pre-prod" = "repo:acme-lab@111/finrisk-infra@1001:environment:infra-pre-prod"
        "finrisk-infra-apply-prod"     = "repo:acme-lab@111/finrisk-infra@1001:environment:infra-prod"
        "finrisk-app-build"            = "repo:acme-lab@111/finrisk-app@1002:ref:refs/heads/main"
        "finrisk-app-deploy-dev"       = "repo:acme-lab@111/finrisk-app@1002:environment:dev"
        "finrisk-app-deploy-sit"       = "repo:acme-lab@111/finrisk-app@1002:environment:sit"
        "finrisk-app-deploy-pre-prod"  = "repo:acme-lab@111/finrisk-app@1002:environment:pre-prod"
        "finrisk-app-deploy-prod"      = "repo:acme-lab@111/finrisk-app@1002:environment:prod"
        "finrisk-ml-train"             = "repo:acme-lab@111/finrisk-ml@1003:environment:ml"
        "finrisk-ml-approve"           = "repo:acme-lab@111/finrisk-ml@1003:environment:model-approval"
        "finrisk-ml-feedback"          = "repo:acme-lab@111/finrisk-ml@1003:environment:simulation"
        "finrisk-ml-promote-dev"       = "repo:acme-lab@111/finrisk-ml@1003:environment:dev"
        "finrisk-ml-promote-sit"       = "repo:acme-lab@111/finrisk-ml@1003:environment:sit"
        "finrisk-ml-promote-pre-prod"  = "repo:acme-lab@111/finrisk-ml@1003:environment:pre-prod"
        "finrisk-ml-promote-prod"      = "repo:acme-lab@111/finrisk-ml@1003:environment:prod"
        "finrisk-kb-build"             = "repo:acme-lab@111/finrisk-knowledge@1004:ref:refs/heads/main"
        "finrisk-kb-promote-dev"       = "repo:acme-lab@111/finrisk-knowledge@1004:environment:dev"
        "finrisk-kb-promote-sit"       = "repo:acme-lab@111/finrisk-knowledge@1004:environment:sit"
        "finrisk-kb-promote-pre-prod"  = "repo:acme-lab@111/finrisk-knowledge@1004:environment:pre-prod"
        "finrisk-kb-promote-prod"      = "repo:acme-lab@111/finrisk-knowledge@1004:environment:prod"
      } :
      jsondecode(aws_iam_role.this[name].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == sub
    ])
    error_message = "With immutable prefixes every role must trust prefix + its own suffix, exactly."
  }

  # Still exact: one StringEquals, one sub, no pattern characters, the audience unchanged.
  assert {
    condition = alltrue([
      for name, r in aws_iam_role.this :
      keys(jsondecode(r.assume_role_policy).Statement[0].Condition) == ["StringEquals"] &&
      !strcontains(r.assume_role_policy, "*") && !strcontains(r.assume_role_policy, "?") &&
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    ])
    error_message = "Immutable subjects must not loosen the trust policy."
  }

  # No role trusts another repository's subject: a role of repository X never mentions the id of Y.
  assert {
    condition = alltrue([
      for name, r in aws_iam_role.this : alltrue([
        for other_id in ["1001", "1002", "1003", "1004"] :
        strcontains(r.assume_role_policy, "@${other_id}:") == (
          (startswith(name, "finrisk-infra-") && other_id == "1001") ||
          (startswith(name, "finrisk-app-") && other_id == "1002") ||
          (startswith(name, "finrisk-ml-") && other_id == "1003") ||
          (startswith(name, "finrisk-kb-") && other_id == "1004")
        )
      ])
    ])
    error_message = "A role names another repository's immutable sub."
  }

  assert {
    condition = output.trusted_sub_prefixes == {
      infra     = "repo:acme-lab@111/finrisk-infra@1001"
      app       = "repo:acme-lab@111/finrisk-app@1002"
      ml        = "repo:acme-lab@111/finrisk-ml@1003"
      knowledge = "repo:acme-lab@111/finrisk-knowledge@1004"
    }
    error_message = "The output must show which prefix each repository's roles trust."
  }
}

run "a_repository_without_a_prefix_keeps_the_classic_sub" {
  command = plan

  variables {
    sub_prefixes = {
      infra = "repo:acme-lab@111/finrisk-infra@1001"
    }
  }

  assert {
    condition = alltrue([
      jsondecode(aws_iam_role.this["finrisk-infra-plan"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:acme-lab@111/finrisk-infra@1001:pull_request",
      jsondecode(aws_iam_role.this["finrisk-app-deploy-prod"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:acme-lab/finrisk-app:environment:prod",
      jsondecode(aws_iam_role.this["finrisk-ml-approve"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:acme-lab/finrisk-ml:environment:model-approval",
      jsondecode(aws_iam_role.this["finrisk-kb-build"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:acme-lab/finrisk-knowledge:ref:refs/heads/main",
    ])
    error_message = "A key missing from sub_prefixes falls back to repo:<org>/<name>; a given key is used as given."
  }
}

run "a_prefix_must_be_the_exact_prefix_of_its_own_repository" {
  command = plan

  # app's prefix under the infra key: the infra roles would trust the app repository.
  variables {
    sub_prefixes = {
      infra = "repo:acme-lab@111/finrisk-app@1002"
    }
  }

  expect_failures = [var.sub_prefixes]
}

run "a_prefix_of_another_organisation_is_refused" {
  command = plan

  variables {
    sub_prefixes = {
      app = "repo:evil-org@999/finrisk-app@1002"
    }
  }

  expect_failures = [var.sub_prefixes]
}

run "a_prefix_cannot_be_a_wildcard_or_carry_a_suffix" {
  command = plan

  variables {
    sub_prefixes = {
      app = "repo:acme-lab@111/finrisk-app@*"
    }
  }

  expect_failures = [var.sub_prefixes]
}

run "a_prefix_must_start_with_repo_colon" {
  command = plan

  variables {
    sub_prefixes = {
      ml = "acme-lab@111/finrisk-ml@1003"
    }
  }

  expect_failures = [var.sub_prefixes]
}

run "a_prefix_cannot_already_hold_a_suffix" {
  command = plan

  variables {
    sub_prefixes = {
      knowledge = "repo:acme-lab@111/finrisk-knowledge@1004:environment:prod"
    }
  }

  expect_failures = [var.sub_prefixes]
}

run "a_prefix_for_an_unknown_repository_key_is_refused" {
  command = plan

  variables {
    sub_prefixes = {
      other = "repo:acme-lab@111/finrisk-other@1005"
    }
  }

  expect_failures = [var.sub_prefixes]
}

# ------------------------------------------------------------------ the identity provider
run "the_provider_is_created_once_for_github" {
  command = plan

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com" && aws_iam_openid_connect_provider.github[0].client_id_list == toset(["sts.amazonaws.com"])
    error_message = "One GitHub OIDC provider with the audience sts.amazonaws.com."
  }
}

run "an_existing_provider_can_be_reused" {
  command = plan

  variables {
    create_oidc_provider = false
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "create_oidc_provider = false must not create a second provider."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this["finrisk-app-build"].assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "The roles must still trust the account's GitHub provider."
  }
}

# ------------------------------------------------------------------ the inputs cannot be bent into a wildcard
run "the_organisation_cannot_contain_a_slash_or_a_wildcard" {
  command = plan

  variables {
    github_org = "acme/lab"
  }

  expect_failures = [var.github_org]
}

run "a_repository_name_cannot_become_a_wildcard" {
  command = plan

  variables {
    repos = {
      infra     = "finrisk-*"
      app       = "finrisk-app"
      ml        = "finrisk-ml"
      knowledge = "finrisk-knowledge"
    }
  }

  expect_failures = [var.repos]
}

run "the_four_repositories_are_required" {
  command = plan

  variables {
    repos = {
      infra = "finrisk-infra"
      app   = "finrisk-app"
    }
  }

  expect_failures = [var.repos]
}

# ------------------------------------------------------------------ what each role may do (needs `apply` against the mock)
run "policies_fit_in_iam_and_nobody_gets_admin" {
  command = apply

  # IAM allows 10,240 characters of inline policy per role (whitespace excluded; ours is compact JSON, so this is a bound).
  assert {
    condition     = alltrue([for name, p in aws_iam_role_policy.this : length(p.policy) < 10240])
    error_message = "A role's inline policy is over the 10,240 character IAM limit."
  }

  assert {
    condition = alltrue([
      for name, p in aws_iam_role_policy.this :
      !strcontains(p.policy, "AdministratorAccess") && !strcontains(p.policy, "\"iam:*\"") && !strcontains(p.policy, "\"s3:*\"") &&
      !strcontains(p.policy, "\"ecr:*\"") && !strcontains(p.policy, "\"ssm:*\"") && !strcontains(p.policy, "\"sagemaker:*\"") &&
      !strcontains(p.policy, "\"Action\":\"*\"") && !strcontains(p.policy, "\"Action\":[\"*\"")
    ])
    error_message = "A policy grants all actions of a service. Only lambda:* on one named function is allowed."
  }

  # lambda:* exists once per environment, on the one function of that environment.
  assert {
    condition = alltrue([
      for e in ["dev", "sit", "pre-prod", "prod"] :
      strcontains(aws_iam_role_policy.this["finrisk-app-deploy-${e}"].policy, ":function:finrisk-${e}\"")
    ])
    error_message = "Each app deploy role must name its own Lambda function."
  }

  # Statements without a resource ("*") never carry a write action except the ECR login.
  assert {
    condition = alltrue([
      for name, p in aws_iam_role_policy.this : alltrue([
        for s in jsondecode(p.policy).Statement :
        s.Resource != "*" || alltrue([for a in tolist(s.Action) : can(regex("^(ec2|elasticloadbalancing|application-autoscaling|ecs|logs|ssm):(Describe|List)|^ecr:GetAuthorizationToken$|^sagemaker:List(EndpointConfigs|Models)$", a))])
      ])
    ])
    error_message = "A statement on Resource * may only list/describe (or log in to ECR)."
  }
}

run "the_plan_and_drift_roles_cannot_change_anything" {
  command = apply

  assert {
    condition = alltrue([
      for name in ["finrisk-infra-plan", "finrisk-infra-drift"] : alltrue([
        for s in jsondecode(aws_iam_role_policy.this[name].policy).Statement :
        alltrue([for a in tolist(s.Action) : can(regex("^[a-z0-9-]+:(Get|List|Describe)", a))])
      ])
    ])
    error_message = "The plan/drift policy contains an action that is not Get*, List* or Describe*."
  }

  assert {
    condition     = aws_iam_role_policy.this["finrisk-infra-plan"].policy == aws_iam_role_policy.this["finrisk-infra-drift"].policy
    error_message = "Plan and drift use the same read-only policy."
  }

  # No state WRITE and no lock file: the plan runs with -lock=false.
  assert {
    condition     = !strcontains(aws_iam_role_policy.this["finrisk-infra-plan"].policy, "tflock") && !strcontains(aws_iam_role_policy.this["finrisk-infra-plan"].policy, "s3:PutObject")
    error_message = "The plan role must not write state or lock files."
  }
}

run "only_apply_shared_may_write_a_repository_policy" {
  command = apply

  # shared/ecr.tf writes the policy that lets Lambda pull finrisk-app; the app deploy roles stay read-only on it.
  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "ecr:SetRepositoryPolicy") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "ecr:DeleteRepositoryPolicy") &&
      alltrue([
        for name, p in aws_iam_role_policy.this :
        name == "finrisk-infra-apply-shared" || !strcontains(p.policy, "ecr:SetRepositoryPolicy")
      ])
    )
    error_message = "Only finrisk-infra-apply-shared may call ecr:SetRepositoryPolicy."
  }
}

run "each_apply_and_deploy_role_touches_only_its_own_environment" {
  command = apply

  # prod's state, names and parameters never appear in dev's policy, and vice versa.
  assert {
    condition = alltrue([
      for family in ["finrisk-infra-apply", "finrisk-app-deploy"] : alltrue([
        for e in ["dev", "sit", "pre-prod", "prod"] : alltrue([
          for other in [for x in ["dev", "sit", "pre-prod", "prod"] : x if x != e] :
          !strcontains(aws_iam_role_policy.this["${family}-${e}"].policy, "env:/${other}/") &&
          !strcontains(aws_iam_role_policy.this["${family}-${e}"].policy, "/finrisk/${other}/") &&
          !strcontains(aws_iam_role_policy.this["${family}-${e}"].policy, "role/finrisk-${other}-") &&
          !strcontains(aws_iam_role_policy.this["${family}-${e}"].policy, "function:finrisk-${other}\"")
        ])
      ])
    ])
    error_message = "An apply/deploy policy names another environment's state, parameters, roles or function."
  }

  # State: the infra stack and the service stack use different objects, each per workspace.
  assert {
    condition = alltrue([
      for e in ["dev", "sit", "pre-prod", "prod"] :
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-${e}"].policy, "env:/${e}/infra/env.tfstate") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-${e}"].policy, "env:/${e}/infra/env.tfstate.tflock") &&
      !strcontains(aws_iam_role_policy.this["finrisk-infra-apply-${e}"].policy, "app/service.tfstate") &&
      strcontains(aws_iam_role_policy.this["finrisk-app-deploy-${e}"].policy, "env:/${e}/app/service.tfstate") &&
      !strcontains(aws_iam_role_policy.this["finrisk-app-deploy-${e}"].policy, "infra/env.tfstate")
    ])
    error_message = "Each stack's role reaches only its own state key (infra/env.tfstate vs app/service.tfstate) in its own workspace."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "infra/shared.tfstate") && !strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "env:/dev/") && !strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "env:/prod/")
    error_message = "apply-shared reaches infra/shared.tfstate (default workspace) and no environment's state."
  }
}

run "the_app_and_knowledge_and_model_roles_do_exactly_what_the_contract_says" {
  command = apply

  # app-build: ECR push to finrisk-app only.
  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-app-build"].policy, "repository/finrisk-app") &&
      !strcontains(aws_iam_role_policy.this["finrisk-app-build"].policy, "finrisk-train") &&
      !strcontains(aws_iam_role_policy.this["finrisk-app-build"].policy, "lambda") &&
      !strcontains(aws_iam_role_policy.this["finrisk-app-build"].policy, "ssm")
    )
    error_message = "app-build pushes to finrisk-app and does nothing else."
  }

  # ml-train STARTS the pipelines and the backfill; it neither trains, registers nor approves itself (the pipeline does, with the
  # execution role); approve approves but does not train.
  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:CreatePipeline") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:UpdatePipeline") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:StartPipelineExecution") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:DescribePipelineExecution") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:ListPipelineExecutionSteps") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:StopPipelineExecution") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:CreateProcessingJob") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:CreateTrainingJob") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:CreateModelPackage\"") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "CreateHyperParameterTuningJob") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "UpdateModelPackage") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "repository/finrisk-train") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "iam:PassedToService")
    )
    error_message = "ml-train: pipelines + backfill + push finrisk-train + PassRole to SageMaker; never train directly, register or approve."
  }

  # Both pipelines, by name, and their executions as their own resource type.
  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "pipeline/finrisk-train\"") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "pipeline/finrisk-monitor\"") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "pipeline/finrisk-train/execution/*") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "pipeline/finrisk-monitor/execution/*") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "processing-job/finrisk-backfill-*") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "pipeline/*")
    )
    error_message = "ml-train names the two pipelines, their executions and the backfill jobs; no pipeline wildcard."
  }

  # What ml-train may read from the ML bucket: datasets/, monitoring/, the backfill report -- never raw/ as a whole or labels/.
  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "finrisk-ml-123456789012-ap-southeast-2-an/datasets/*") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "finrisk-ml-123456789012-ap-southeast-2-an/monitoring/*") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "an/raw/*/backfill_report.json") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "an/raw/*\"") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "/labels/") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "/replay/") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "alarm:finrisk-prod-model-*") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "sagemaker:CreatePresignedMlflowAppUrl") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "parameter/finrisk/prod/model")
    )
    error_message = "ml-train reads datasets/, monitoring/ and the backfill report, the prod model alarms, the prod pointer; opens the MLflow UI."
  }

  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-ml-approve"].policy, "sagemaker:UpdateModelPackage") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-approve"].policy, "CreateTrainingJob") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-approve"].policy, "Pipeline") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-approve"].policy, "ssm:") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-approve"].policy, "s3:")
    )
    error_message = "ml-approve changes an approval status (and the model card inside the package) and nothing else."
  }

  # promote roles: the registry (read) + THEIR environment's pointer.
  assert {
    condition = alltrue([
      for e in ["dev", "sit", "pre-prod", "prod"] :
      strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "parameter/finrisk/${e}/model") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "parameter/finrisk/${e}/app_url") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "parameter/finrisk/${e}/endpoint_role_arn") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "/index") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "UpdateModelPackage") &&
      strcontains(aws_iam_role_policy.this["finrisk-kb-promote-${e}"].policy, "parameter/finrisk/${e}/index") &&
      strcontains(aws_iam_role_policy.this["finrisk-kb-promote-${e}"].policy, "parameter/finrisk/${e}/app_url") &&
      !strcontains(aws_iam_role_policy.this["finrisk-kb-promote-${e}"].policy, "/model")
    ])
    error_message = "A promote role moves ONE pointer of ONE environment (ml: model, knowledge: index) and reads app_url."
  }

  # kb-build: the KB bucket's indexes/ and Titan, in the Region, nothing else.
  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-kb-build"].policy, "finrisk-kb-123456789012-ap-southeast-2-an/indexes/*") &&
      strcontains(aws_iam_role_policy.this["finrisk-kb-build"].policy, "arn:aws:bedrock:ap-southeast-2::foundation-model/amazon.titan-embed-text-v2:0") &&
      !strcontains(aws_iam_role_policy.this["finrisk-kb-build"].policy, "deepseek") &&
      !strcontains(aws_iam_role_policy.this["finrisk-kb-build"].policy, "finrisk-ml")
    )
    error_message = "kb-build: indexes/* of the KB bucket and the Titan embedding model only."
  }

  # The names the roles point at are the names shared/ creates (shared/tests/shared.tftest.hcl asserts the same strings).
  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "finrisk-ml-123456789012-ap-southeast-2-an/data/*") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "role/finrisk-sagemaker-exec") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-train"].policy, "model-package-group/finrisk-fraud-model") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "repository/finrisk-app") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "repository/finrisk-train") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "finrisk-kb-123456789012-ap-southeast-2-an")
    )
    error_message = "A name in bootstrap no longer matches the one shared/ creates."
  }
}

# ------------------------------------------------------------------ what scripts/github_bootstrap.sh reads
run "outputs_feed_the_github_bootstrap_script" {
  command = apply

  # Secrets (they hold the account id) and Environment secrets are sensitive; variables are plain.
  assert {
    condition     = toset(keys(nonsensitive(output.github_repo_secrets["infra"]))) == toset(["TF_STATE_BUCKET", "AWS_PLAN_ROLE_ARN", "AWS_DRIFT_ROLE_ARN"])
    error_message = "finrisk-infra secrets."
  }

  assert {
    condition     = toset(keys(nonsensitive(output.github_repo_secrets["app"]))) == toset(["TF_STATE_BUCKET", "AWS_BUILD_ROLE_ARN", "ECR_REPOSITORY"])
    error_message = "finrisk-app secrets."
  }

  assert {
    condition     = length(keys(nonsensitive(output.github_repo_secrets["ml"]))) == 0
    error_message = "finrisk-ml has no repository secrets: its ML names come from SSM."
  }

  assert {
    condition     = toset(keys(nonsensitive(output.github_repo_secrets["knowledge"]))) == toset(["KB_BUCKET", "AWS_KB_BUILD_ROLE_ARN"])
    error_message = "finrisk-knowledge secrets."
  }

  assert {
    condition     = nonsensitive(output.github_repo_secrets["app"]["ECR_REPOSITORY"]) == "123456789012.dkr.ecr.ap-southeast-2.amazonaws.com/finrisk-app"
    error_message = "ECR_REPOSITORY is the full repository URL."
  }

  assert {
    condition = (
      output.github_repo_variables["infra"] == { AWS_REGION = "ap-southeast-2" } &&
      output.github_repo_variables["app"] == { AWS_REGION = "ap-southeast-2" } &&
      output.github_repo_variables["knowledge"] == { AWS_REGION = "ap-southeast-2" } &&
      output.github_repo_variables["ml"] == { AWS_REGION = "ap-southeast-2" }
    )
    error_message = "Variables are only the Region (every repo): no account id."
  }

  assert {
    condition = (
      toset(output.github_environments["infra"]) == toset(["infra-dev", "infra-pre-prod", "infra-prod", "infra-shared", "infra-sit"]) &&
      toset(output.github_environments["app"]) == toset(["dev", "pre-prod", "prod", "sit"]) &&
      toset(output.github_environments["knowledge"]) == toset(["dev", "pre-prod", "prod", "sit"]) &&
      toset(output.github_environments["ml"]) == toset(["dev", "ml", "model-approval", "pre-prod", "prod", "simulation", "sit"])
    )
    error_message = "Environments per repository (spec 3.2)."
  }

  assert {
    condition = alltrue([
      for repo, envs in nonsensitive(output.github_environment_secrets) :
      toset(keys(envs)) == toset(output.github_environments[repo]) && alltrue([for env, s in envs : length(keys(s)) == 1])
    ])
    error_message = "Every Environment gets exactly one secret."
  }

  # ONE naming rule: every Environment's secret is AWS_ROLE_ARN (a job with `environment:` reads secrets.AWS_ROLE_ARN).
  assert {
    condition = alltrue([
      for repo, envs in nonsensitive(output.github_environment_secrets) :
      alltrue([for env, s in envs : keys(s) == ["AWS_ROLE_ARN"]])
    ])
    error_message = "Every Environment of every repository uses the secret name AWS_ROLE_ARN."
  }

  # ... and holds THAT Environment's role.
  assert {
    condition = (
      nonsensitive(output.github_environment_secrets["ml"]["ml"]["AWS_ROLE_ARN"]) == aws_iam_role.this["finrisk-ml-train"].arn &&
      nonsensitive(output.github_environment_secrets["ml"]["model-approval"]["AWS_ROLE_ARN"]) == aws_iam_role.this["finrisk-ml-approve"].arn &&
      nonsensitive(output.github_environment_secrets["ml"]["simulation"]["AWS_ROLE_ARN"]) == aws_iam_role.this["finrisk-ml-feedback"].arn &&
      nonsensitive(output.github_environment_secrets["ml"]["pre-prod"]["AWS_ROLE_ARN"]) == aws_iam_role.this["finrisk-ml-promote-pre-prod"].arn &&
      nonsensitive(output.github_environment_secrets["app"]["prod"]["AWS_ROLE_ARN"]) == aws_iam_role.this["finrisk-app-deploy-prod"].arn &&
      nonsensitive(output.github_environment_secrets["knowledge"]["sit"]["AWS_ROLE_ARN"]) == aws_iam_role.this["finrisk-kb-promote-sit"].arn &&
      nonsensitive(output.github_environment_secrets["infra"]["infra-shared"]["AWS_ROLE_ARN"]) == aws_iam_role.this["finrisk-infra-apply-shared"].arn
    )
    error_message = "An Environment's AWS_ROLE_ARN must be the role of that Environment."
  }

  assert {
    condition     = output.github_org == "acme-lab" && output.repositories["knowledge"] == "finrisk-knowledge" && output.aws_region == "ap-southeast-2"
    error_message = "The script checks the organisation and maps repository keys to names."
  }
}

# ------------------------------------------------------------------ week 13b: promote roles, the feedback role, the shared apply role
run "promote_roles_name_only_their_own_environment_and_pass_only_their_endpoint_role" {
  command = apply

  # Every endpoint, config and model name in the policy starts finrisk-<env>-fraud; PassRole names finrisk-<env>-endpoint
  # and nothing else; no other environment's name appears anywhere.
  assert {
    condition = alltrue([
      for e in ["dev", "sit", "pre-prod", "prod"] : (
        strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "endpoint/finrisk-${e}-fraud\"") &&
        strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "endpoint-config/finrisk-${e}-fraud-*") &&
        strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "model/finrisk-${e}-fraud-*") &&
        strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "sagemaker:InvokeEndpoint") &&
        strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "sagemaker:UpdateEndpoint") &&
        strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "sagemaker:DeleteEndpoint") &&
        strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "alarm:finrisk-${e}-endpoint-*") &&
        [for s in jsondecode(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy).Statement : s.Resource if s.Sid == "PassTheEndpointRoleOfThisEnvironment"][0] == "arn:aws:iam::123456789012:role/finrisk-${e}-endpoint" &&
        [for s in jsondecode(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy).Statement : s.Condition if s.Sid == "PassTheEndpointRoleOfThisEnvironment"][0] == { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } } &&
        length([for s in jsondecode(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy).Statement : s if contains(tolist(s.Action), "iam:PassRole")]) == 1
      )
    ])
    error_message = "A promote role manages the endpoint, configs and models of its own environment and passes only finrisk-<env>-endpoint to SageMaker."
  }

  assert {
    condition = alltrue([
      for e in ["dev", "sit", "pre-prod", "prod"] : alltrue([
        for other in [for x in ["dev", "sit", "pre-prod", "prod"] : x if x != e] :
        # "-fraud" keeps finrisk-prod-... from matching inside finrisk-pre-prod-...: the other environment's name is never used.
        !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "/finrisk-${other}-fraud") &&
        !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "finrisk-${other}-endpoint") &&
        !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "/finrisk/${other}/")
      ])
    ])
    error_message = "A promote role names another environment's endpoint, role, alarm or parameter."
  }

  # No wildcard in front of the environment: nothing like endpoint/* or model/*.
  assert {
    condition = alltrue([
      for e in ["dev", "sit", "pre-prod", "prod"] : (
        !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, ":endpoint/*") &&
        !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, ":model/*") &&
        !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, ":endpoint-config/*") &&
        !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, ":role/*") &&
        !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "UpdateModelPackage") &&
        !strcontains(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy, "Pipeline")
      )
    ])
    error_message = "A promote role has no wildcard endpoint/model/role and neither approves nor starts a pipeline."
  }

  # The pointer is written for this environment only.
  assert {
    condition = alltrue([
      for e in ["dev", "sit", "pre-prod", "prod"] :
      [for s in jsondecode(aws_iam_role_policy.this["finrisk-ml-promote-${e}"].policy).Statement : s.Resource if s.Sid == "ReadAndMoveTheModelPointer"][0] == "arn:aws:ssm:ap-southeast-2:123456789012:parameter/finrisk/${e}/model"
    ])
    error_message = "The model pointer a promote role may write is its own environment's."
  }
}

run "the_feedback_role_cannot_touch_models_pointers_the_registry_or_an_endpoint" {
  command = apply

  # What it CAN do.
  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "finrisk-ml-123456789012-ap-southeast-2-an/replay/*") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "finrisk-ml-123456789012-ap-southeast-2-an/labels/source=feedback/*") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "sagemaker:BatchWriteRecord") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "sagemaker:PutRecord") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "sagemaker:DescribeFeatureGroup") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "feature-group/finrisk-transactions") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "parameter/finrisk/prod/app_url") &&
      strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "parameter/finrisk/shared/*")
    )
    error_message = "The feedback role reads replay/, writes labels/source=feedback/, records features, reads the prod URL and the shared names."
  }

  # What it CANNOT: models, metrics, datasets, raw, the pointers, the registry, any endpoint, any role, any pipeline.
  assert {
    condition = (
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "/models/") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "/metrics/") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "/datasets/") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "/raw/") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "/capture/") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "/model\"") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "ssm:Put") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "ModelPackage") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "Endpoint") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "Pipeline") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "iam:") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "s3:DeleteObject") &&
      !strcontains(aws_iam_role_policy.this["finrisk-ml-feedback"].policy, "ecr:")
    )
    error_message = "The feedback role must not touch models/, metrics/, datasets/, raw/, capture/, a pointer, the registry, an endpoint, a pipeline, IAM or ECR."
  }

  # It reads and writes S3 only under the two prefixes; the writes are PutObject (labels) -- the one read is the replay set.
  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.this["finrisk-ml-feedback"].policy).Statement : s.Action if s.Sid == "ReadTheReplaySet"][0] == ["s3:GetObject"] &&
      [for s in jsondecode(aws_iam_role_policy.this["finrisk-ml-feedback"].policy).Statement : s.Resource if s.Sid == "WriteFeedbackLabels"][0] == "arn:aws:s3:::finrisk-ml-123456789012-ap-southeast-2-an/labels/source=feedback/*" &&
      [for s in jsondecode(aws_iam_role_policy.this["finrisk-ml-feedback"].policy).Statement : s.Resource if s.Sid == "RecordFeaturesInTheFeatureStore"][0] == "arn:aws:sagemaker:ap-southeast-2:123456789012:feature-group/finrisk-transactions"
    )
    error_message = "Replay is read-only, labels are written under source=feedback only, features go to the one feature group."
  }
}

run "the_pipeline_roles_are_named_exactly_and_every_policy_fits_in_iam" {
  command = apply

  # IAM's inline limit is 10,240 characters per ROLE (whitespace excluded). 9,000 leaves room for one more statement.
  assert {
    condition     = alltrue([for name, p in aws_iam_role_policy.this : length(p.policy) < 9000])
    error_message = "A role's inline policy is within 1,240 characters of the 10,240 IAM limit; split it before adding more."
  }

  # apply-shared may write exactly five role names, PassRole each only to its own service.
  assert {
    condition = toset([for s in jsondecode(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy).Statement : s.Resource if s.Sid == "OwnTheSharedRoles"][0]) == toset([
      "arn:aws:iam::123456789012:role/finrisk-sagemaker-exec", "arn:aws:iam::123456789012:role/finrisk-mlflow",
      "arn:aws:iam::123456789012:role/finrisk-studio", "arn:aws:iam::123456789012:role/finrisk-scheduler", "arn:aws:iam::123456789012:role/finrisk-events",
    ])
    error_message = "apply-shared owns exactly: sagemaker-exec, mlflow, studio, scheduler, events."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy).Statement : s.Condition if s.Sid == "PassTheSchedulerRoleToScheduler"][0] == { StringEquals = { "iam:PassedToService" = "scheduler.amazonaws.com" } } &&
      [for s in jsondecode(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy).Statement : s.Condition if s.Sid == "PassTheEventsRoleToEventBridge"][0] == { StringEquals = { "iam:PassedToService" = "events.amazonaws.com" } } &&
      [for s in jsondecode(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy).Statement : s.Condition if s.Sid == "PassTheSageMakerRolesToSageMaker"][0] == { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } }
    )
    error_message = "Each shared role may be handed only to its own service."
  }

  # The new resources are named, except the three whose ids AWS chooses (domain, profile, MLflow App).
  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "feature-group/finrisk-transactions") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "database/finrisk_ml") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "workgroup/finrisk") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "schedule-group/finrisk") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "rule/finrisk-retrain-on-drift") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "mlflow-app/*") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "domain/*") &&
      !strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "rule/*") &&
      !strcontains(aws_iam_role_policy.this["finrisk-infra-apply-shared"].policy, "iam:CreateServiceLinkedRole")
    )
    error_message = "apply-shared names the feature group, database, workgroup, schedule group and rule; only domain, profile and MLflow App use a pattern."
  }

  # The environment apply roles may write alarms named for their own environment only.
  assert {
    condition = alltrue([
      for e in ["dev", "sit", "pre-prod", "prod"] : (
        strcontains(aws_iam_role_policy.this["finrisk-infra-apply-${e}"].policy, "alarm:finrisk-${e}-*") &&
        alltrue([for other in [for x in ["dev", "sit", "pre-prod", "prod"] : x if x != e] : !strcontains(aws_iam_role_policy.this["finrisk-infra-apply-${e}"].policy, "alarm:finrisk-${other}-")])
      )
    ])
    error_message = "An environment apply role writes only alarms named finrisk-<its env>-*."
  }

  # Nobody but the shared apply role can create Studio, Feature Store, MLflow, Glue, Athena, schedules or rules.
  assert {
    condition = alltrue([
      for name, p in aws_iam_role_policy.this :
      name == "finrisk-infra-apply-shared" || (
        !strcontains(p.policy, "sagemaker:CreateDomain") && !strcontains(p.policy, "sagemaker:CreateFeatureGroup") &&
        !strcontains(p.policy, "sagemaker:CreateMlflowApp") && !strcontains(p.policy, "glue:CreateDatabase") &&
        !strcontains(p.policy, "athena:CreateWorkGroup") && !strcontains(p.policy, "scheduler:CreateSchedule") &&
        !strcontains(p.policy, "events:PutRule")
      )
    ])
    error_message = "Only finrisk-infra-apply-shared may create the shared SageMaker, Glue, Athena, Scheduler and EventBridge resources."
  }

  # The execution role is handed over by ml-train (pipelines) and apply-shared (feature group) only.
  assert {
    condition = alltrue([
      for name, p in aws_iam_role_policy.this :
      contains(["finrisk-ml-train", "finrisk-infra-apply-shared"], name) || !strcontains(p.policy, "role/finrisk-sagemaker-exec")
    ])
    error_message = "Only ml-train and apply-shared may name the SageMaker execution role (to pass it on)."
  }
}

run "the_plan_role_reads_the_new_resources_and_still_cannot_write" {
  command = apply

  assert {
    condition = (
      strcontains(aws_iam_role_policy.this["finrisk-infra-plan"].policy, "sagemaker:DescribeFeatureGroup") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-plan"].policy, "sagemaker:DescribeMlflowApp") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-plan"].policy, "glue:GetTable") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-plan"].policy, "athena:GetWorkGroup") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-plan"].policy, "scheduler:GetSchedule") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-plan"].policy, "events:ListTargetsByRule") &&
      strcontains(aws_iam_role_policy.this["finrisk-infra-plan"].policy, "cloudwatch:DescribeAlarms")
    )
    error_message = "Plan and drift must be able to read every new resource kind."
  }
}

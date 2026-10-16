# finrisk-infra

The **infrastructure repository** of the finrisk course project. It builds everything the other three repositories stand on:
the Terraform state bucket, the key-less login from GitHub to AWS (OIDC) and **every IAM role the four pipelines use**,
the container registries, the ML and knowledge-base buckets, and the foundations of each environment (bucket, log group,
the identity the running app wears, and the parameters other pipelines read).

| Repository | Pipeline | What it ships to an environment |
| --- | --- | --- |
| **finrisk-infra** (this one) | `infra-ci`, `infra-deliver`, `drift` | the foundations: buckets, roles, parameters |
| finrisk-app | `ci`, `deliver`, `rollback`, `teardown` | the service **image** (by digest) |
| finrisk-ml | `ml-ci`, `train`, `approve-model`, `promote-model` | the **model** version (a pointer) |
| finrisk-knowledge | `kb-ci`, `ingest`, `promote-index` | the **index** version (a pointer) |

What runs in an environment is *image digest + model version + index version*, each promoted by its own pipeline.

## How changes move (trunk-based, one stage per environment)

```
feature/*  ->  pull request  ->  main            main is always releasable; environments are STAGES, not branches

 pull request:  terraform-checks (offline: fmt, validate, terraform test with a mock AWS provider, pytest)
                plan            (read-only: shared + dev + sit + pre-prod + prod, with the + ~ - counts)
 merge to main (shared/** or envs/** changed):
                apply-shared -> apply-dev -> apply-sit -> apply-pre-prod -> apply-prod
                (Environments infra-shared, infra-dev, infra-sit, infra-pre-prod, infra-prod;
                 a reviewer on infra-shared, infra-pre-prod and infra-prod)
 every night:   drift  (plan -detailed-exitcode per scope; exit 2 = the job fails and lists the addresses)
```

Each stage runs `init`, then `plan -out tfplan`, then `apply tfplan`: **the plan that was shown is the plan that is applied.**

### One AWS account, four environments
Industry practice is one AWS account per environment (AWS Organizations) plus shared tooling accounts. This course has one
Free-plan account, so the environments are separated by **name prefix** `finrisk-<env>-...`, **one Terraform state per
environment** (a workspace each), **one IAM role per environment and pipeline**, and tags.

## Layout

```
bootstrap/   by hand, once      state bucket, GitHub OIDC provider, ALL roles for the four repositories (local state)
shared/      pipeline           ECR finrisk-app + finrisk-train, ML bucket, KB bucket, SageMaker role + model group, /finrisk/shared/*
envs/        pipeline           per environment (workspace = env): bucket, log group, runtime role, ECS roles, /finrisk/<env>/*
scripts/     tf.sh (init/plan/apply for a scope) - tf_checks.sh (offline checks) - github_bootstrap.sh - plan_summary.py
.github/workflows/   infra-ci.yml - infra-deliver.yml - drift.yml
tests/       pytest (scripts, workflows, lock files) - bootstrap/tests, shared/tests, envs/tests hold the `terraform test` files
```

| Scope | Folder | State object | Workspace | Variables |
| --- | --- | --- | --- | --- |
| `shared` | `shared/` | `infra/shared.tfstate` | default | defaults |
| `dev` `sit` `pre-prod` `prod` | `envs/` | `env:/<env>/infra/env.tfstate` | `<env>` | `<env>.tfvars` |

`envs/` refuses to run when the workspace is not the env (`terraform_data.workspace_matches_env`, a *precondition*, so the
plan fails before anything changes). The `app/service.tfstate` key belongs to finrisk-app's stack.

### The names (a contract with the other three repositories)

| Thing | Name |
| --- | --- |
| State bucket | `finrisk-tfstate-<acct>-<region>-an` |
| ECR | `finrisk-app` (service image), `finrisk-train` (training image): IMMUTABLE, scan on push, keep the last 10. `finrisk-app` also carries a repository policy that lets Lambda (`finrisk-*` functions only) pull it: Lambda reads the image with its own identity, and writing that statement needs `ecr:SetRepositoryPolicy`, which only `finrisk-infra-apply-shared` has, not the app deploy roles |
| Buckets | `finrisk-ml-<acct>-<region>-an` (`data/`, `models/`, `metrics/`), `finrisk-kb-<acct>-<region>-an` (`indexes/<version>/`), `finrisk-<env>-<acct>-<region>-an` |
| SageMaker | role `finrisk-sagemaker-exec`, model package group `finrisk-fraud-model` |
| Parameters, shared | `/finrisk/shared/` `ecr_app_url` `ecr_train_url` `ml_bucket` `kb_bucket` `sagemaker_role_arn` `model_package_group` |
| Parameters, per env | `/finrisk/<env>/` `runtime_role_arn` `log_group` `bucket` (+ `ecs_execution_role_arn` `ecs_infrastructure_role_arn` in pre-prod and prod) |
| Pointers | `/finrisk/<env>/model`, `/finrisk/<env>/index`: created here as `{"version": null}` with `ignore_changes = [value]`, then **owned by finrisk-ml / finrisk-knowledge** |
| Written by finrisk-app | `/finrisk/<env>/app_url` |

## The IAM roles (all created in `bootstrap/`)

Every role trusts **one** GitHub token: `aud = sts.amazonaws.com` and an **exact** `sub`. No wildcard anywhere.

| Role | Who may become it (`sub` after `repo:<org>/<repo>:`) | May do (by name) |
| --- | --- | --- |
| `finrisk-infra-plan` | `finrisk-infra` `pull_request` | read state, Describe/Get/List. Nothing else |
| `finrisk-infra-drift` | `finrisk-infra` `ref:refs/heads/main` | the same read-only policy, for the nightly run (added: a schedule has no `pull_request` sub) |
| `finrisk-infra-apply-shared` | `finrisk-infra` `environment:infra-shared` | state `infra/shared.tfstate`; the two ECR repos, ML + KB buckets, `finrisk-sagemaker-exec`, the model group, `/finrisk/shared/*` |
| `finrisk-infra-apply-<env>` x4 | `finrisk-infra` `environment:infra-<env>` | state `env:/<env>/infra/env.tfstate`; the env bucket, `/app/finrisk-<env>` log group, roles `finrisk-<env>-*`, `/finrisk/<env>/*`; read `/finrisk/shared/*` |
| `finrisk-app-build` | `finrisk-app` `ref:refs/heads/main` | ECR push to `finrisk-app` only |
| `finrisk-app-deploy-<env>` x4 | `finrisk-app` `environment:<env>` | state `env:/<env>/app/service.tfstate`; Lambda / Express `finrisk-<env>`; PassRole `finrisk-<env>-*`; ECR read; SSM get `/finrisk/shared/*` + `/finrisk/<env>/*`; put `/finrisk/<env>/app_url` |
| `finrisk-ml-train` | `finrisk-ml` `environment:ml` | push `finrisk-train`; pull `finrisk-app`; SageMaker training + register (never approve); PassRole `finrisk-sagemaker-exec`; ML bucket `data/` get+put, `models/` get, `metrics/` get+put; SSM get `/finrisk/prod/model` + `/finrisk/shared/*` |
| `finrisk-ml-approve` | `finrisk-ml` `environment:model-approval` | `UpdateModelPackage` / Describe / List on the group. Nothing else |
| `finrisk-ml-promote-<env>` x4 | `finrisk-ml` `environment:<env>` | registry read; SSM get+put `/finrisk/<env>/model`; get `/finrisk/<env>/app_url` |
| `finrisk-kb-build` | `finrisk-knowledge` `ref:refs/heads/main` | KB bucket `indexes/*` get+put + list; `bedrock:InvokeModel` Titan embeddings; SSM get `/finrisk/prod/index` |
| `finrisk-kb-promote-<env>` x4 | `finrisk-knowledge` `environment:<env>` | KB bucket `indexes/*` get + list; SSM get+put `/finrisk/<env>/index`; get `/finrisk/<env>/app_url` |

The environment runtime role (`finrisk-<env>-runtime`, made by `envs/`) is what the *running service* wears: its own log group
and bucket, `models/*` of the ML bucket and `indexes/*` of the KB bucket (read), `bedrock:InvokeModel` on `deepseek.v3.2` and
`amazon.titan-embed-text-v2:0` in the Region, and `ssm:GetParameter` on `/finrisk/<env>/*` and `/finrisk/shared/*`.

### What is broad, and why
The header of `bootstrap/oidc.tf` lists every exception in full. In short: `ecr:GetAuthorizationToken` on `*` (AWS has no resource
for "log in to ECR"); read-only Describe/List calls on `*` that Terraform's refresh makes; `s3:Get*`/`List*` on a bucket (its
*settings*, not its files); `lambda:*` but only on the function `finrisk-<env>`; ECS Express `cluster/*` and `task-definition/*`
(AWS names them); and the apply roles can write IAM roles named `finrisk-<env>-*`. The guard for that last one is the pipeline
itself: only code on `main`, through an Environment with a reviewer where it matters, ever runs with those roles.
`ecr:SetRepositoryPolicy` / `DeleteRepositoryPolicy` belong to `finrisk-infra-apply-shared` alone (on the two repositories); the app deploy
roles can only *read* the repository policy, which is why `shared/ecr.tf` writes Lambda's pull statement for them.
`iam:CreateServiceLinkedRole` is deliberately **not** granted anywhere.

## Secrets, variables and required checks (set by `scripts/github_bootstrap.sh`)

One naming rule for all four repositories: **a job with `environment:` reads `secrets.AWS_ROLE_ARN`** (an *Environment* secret
holding that Environment's role); a job without an environment reads a *repository* secret named after its role. Values that
contain the account id are secrets (the repositories are public, and GitHub hides secrets in logs); the rest are variables.

| Repository | Repository variables | Repository secrets | Environments (secret `AWS_ROLE_ARN` in each) | Required checks (ruleset `protect-main`) |
| --- | --- | --- | --- | --- |
| finrisk-infra | `AWS_REGION` | `TF_STATE_BUCKET` `AWS_PLAN_ROLE_ARN` `AWS_DRIFT_ROLE_ARN` | `infra-shared` (R) `infra-dev` `infra-sit` `infra-pre-prod` (R) `infra-prod` (R) | `plan` `terraform-checks` |
| finrisk-app | `AWS_REGION` | `TF_STATE_BUCKET` `AWS_BUILD_ROLE_ARN` `ECR_REPOSITORY` | `dev` `sit` `pre-prod` (R) `prod` (R) | `test` `terraform` |
| finrisk-ml | `AWS_REGION` | (none: the ML names come from SSM `/finrisk/shared/*`) | `ml` `model-approval` (R) `dev` `sit` `pre-prod` (R) `prod` (R) | `test` |
| finrisk-knowledge | `AWS_REGION` | `KB_BUCKET` `AWS_KB_BUILD_ROLE_ARN` | `dev` `sit` `pre-prod` (R) `prod` (R) | `kb-check` |

(R) = a required reviewer (you; self-review is allowed because the course is a one-person organisation). Every Environment
accepts deployments from `main` only. The ruleset requires a pull request, the checks above, and forbids force-push and deletion.

## Doing it for the first time

**0. Before you start.** An AWS account with an *admin* IAM user (not the root user), `aws` CLI signed in, Terraform >= 1.15,
`gh` signed in (`gh auth login`) as an owner of the GitHub organisation, `python3`. Create the three ECS service-linked roles once
(free; "has been taken in this account" means they exist, which is fine):

```bash
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com
aws iam create-service-linked-role --aws-service-name elasticloadbalancing.amazonaws.com
aws iam create-service-linked-role --aws-service-name ecs.application-autoscaling.amazonaws.com
```

**1. Bootstrap (by hand, once).** Its state is **local**, because it creates the bucket the other stacks keep their state in.
Work **outside iCloud/Dropbox** in a folder you will not delete, and keep `terraform.tfstate` there (it is your only record of these
resources; it is git-ignored in this repository):

```bash
mkdir -p ~/terraform-labs && cp -R bootstrap ~/terraform-labs/finrisk-bootstrap && cd ~/terraform-labs/finrisk-bootstrap
export TF_PLUGIN_CACHE_DIR=~/.terraform.d/plugin-cache; mkdir -p "$TF_PLUGIN_CACHE_DIR"
terraform init
terraform plan          # read it: 23 roles, 23 policies, 1 provider, 1 bucket (+ its settings)
terraform apply         # -var create_oidc_provider=false if week 13a's practice repo already made the GitHub provider
```

**2. Create the four repositories** in the organisation (public) and push the first commit of each. (`protect-main` blocks direct
pushes, so push *before* step 3. Each repository's first workflow run will fail because its secrets do not exist yet: ignore it.)

**3. Configure GitHub from the outputs.** A dry run first (it prints every command, account ids hidden, and calls nothing):

```bash
bash scripts/github_bootstrap.sh fraud-detection-app --bootstrap-dir ~/terraform-labs/finrisk-bootstrap
bash scripts/github_bootstrap.sh fraud-detection-app --bootstrap-dir ~/terraform-labs/finrisk-bootstrap --apply
```

It sets variables, secrets, Environments (reviewers, `main`-only branch policy), the Environment secrets and the rulesets for
all four repositories. Safe to repeat. (`terraform output -json` prints the secret values: never paste its output anywhere.)

**4. First delivery.** Actions -> `infra-deliver` -> *Run workflow*. It applies `shared`, then each environment; approve the
Environments with a reviewer when GitHub asks. When it is green, the other three repositories can run.

**5. From now on** every change is a pull request: read the `plan` summary, merge, watch the stages.

## Tests

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
bash scripts/tf_checks.sh               # fmt, validate, terraform test (mock provider) for bootstrap, shared, envs
.venv/bin/python -m pytest -q           # scripts, workflows, lock files; add -m "not terraform" to skip the Terraform runs
```

`tf_checks.sh` works in a temporary copy, so nothing lands in your checkout. The `terraform test` files prove, with a *mock* AWS
provider (no account needed): every role trusts exactly one repository and one subject; the plan role cannot change anything; no
role names another environment; the SSM names are the contract's; the pointers ignore value changes; the workspace guard works.

## Drift, in one paragraph
`drift` runs a read-only plan for each scope every night. Exit code 2 means the real AWS differs from the code: the job fails and
the summary lists the addresses, under "Changed outside Terraform" when somebody edited a resource by hand. Fix it by reverting
the click, or by changing the code and merging. (GitHub turns scheduled workflows off after 60 days without a push to a public
repository: press "Enable workflow" if the nightly run stops.)

## Teardown (reverse order, by an admin, from your laptop)
1. finrisk-app `teardown` for each environment (the compute), and delete the model/index pointers' consumers.
2. `envs/`, one workspace at a time: `terraform init -backend-config=...` (the same flags as `scripts/tf.sh`), `terraform workspace
   select <env>`, `terraform destroy -var-file=<env>.tfvars`. pre-prod and prod buckets must be emptied first (every object *version*).
3. `shared/`: empty the ML and KB buckets (every version), then `terraform destroy` (the ECR repos are deleted with their images).
4. `bootstrap/`: empty the state bucket last (every version), then `terraform destroy` in `~/terraform-labs/finrisk-bootstrap`.

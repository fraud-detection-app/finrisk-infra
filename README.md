# finrisk-infra

The **infrastructure repository** of the finrisk course project. It builds everything the other three repositories stand on:
the Terraform state bucket, the key-less login from GitHub to AWS (OIDC) and **every IAM role the four pipelines use**,
the container registries, the ML and knowledge-base buckets, the **data platform and automation of the model block** (Feature
Store, Glue/Athena, MLflow, Studio, schedules, the retrain-on-drift rule), and the foundations of each environment (bucket, log
group, the identity the running app wears, the identity the model **endpoint** wears, the alarms, and the parameters other
pipelines read).

| Repository | Pipeline | What it ships to an environment |
| --- | --- | --- |
| **finrisk-infra** (this one) | `infra-ci`, `infra-deliver`, `drift` | the foundations: buckets, roles, parameters |
| finrisk-app | `ci`, `deliver`, `rollback`, `teardown` | the service **image** (by digest) |
| finrisk-ml | `ml-ci`, `backfill`, `train`, `approve-model`, `promote-model`, `replay`, `monitor`, `teardown` | the **model** version (an endpoint + a pointer) |
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
shared/      pipeline           ECR finrisk-app + finrisk-train, ML + KB buckets, SageMaker role + model group, Feature Store group, Glue/Athena,
                                MLflow App, schedules + retrain-on-drift rule, Studio domain, /finrisk/shared/*
envs/        pipeline           per environment (workspace = env): bucket, log group, runtime role, endpoint role, alarms, ECS roles, /finrisk/<env>/*
scripts/     tf.sh (init/plan/apply for a scope) - tf_checks.sh (offline checks) - sweep.sh (read-only "is anything left?") - oidc_subjects.sh - github_bootstrap.sh - plan_summary.py
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
| SageMaker | role `finrisk-sagemaker-exec` (the pipelines' and jobs' role, the Feature Store's too), model package group `finrisk-fraud-model`, pipelines `finrisk-train` and `finrisk-monitor` (made by finrisk-ml; only the names are fixed here) |
| Data platform | Feature Store group `finrisk-transactions` (offline only), Glue database `finrisk_ml` with tables `transactions` (made by the Feature Store) and `labels`, Athena workgroup `finrisk` |
| MLflow | App `finrisk-mlflow`, role `finrisk-mlflow`, artifacts in `s3://<ml>/mlflow/` |
| Studio | domain `finrisk-studio`, user profile `instructor`, role `finrisk-studio` (read-only); switch off with `create_studio_domain = false` |
| Automation | Scheduler group `finrisk`: `finrisk-weekly-retrain` (Mon 02:00 Sydney, on) and `finrisk-hourly-monitor` (**off** unless `monitor_schedule_enabled = true`), role `finrisk-scheduler`; EventBridge rule `finrisk-retrain-on-drift`, role `finrisk-events` |
| Per env, serving | endpoint `finrisk-<env>-fraud` (made by finrisk-ml), its role `finrisk-<env>-endpoint`; alarms `finrisk-<env>-endpoint-5xx` / `-latency` (pre-prod, prod) and `finrisk-prod-model-drift` / `-prior-shift` / `-quality` (prod) |
| ML bucket folders | `raw/` `data/` `datasets/` `labels/` `replay/` `models/` `metrics/` `monitoring/` `capture/<env>/` `athena/` `feature-store/` `mlflow/` |
| Parameters, shared | `/finrisk/shared/` `ecr_app_url` `ecr_train_url` `ml_bucket` `kb_bucket` `sagemaker_role_arn` `model_package_group` `feature_group` `glue_database` `labels_table` `athena_workgroup` `mlflow_app_arn` `train_pipeline` `monitor_pipeline` `model_image_repo` |
| Parameters, per env | `/finrisk/<env>/` `runtime_role_arn` `log_group` `bucket` `endpoint_role_arn` (+ `ecs_execution_role_arn` `ecs_infrastructure_role_arn` in pre-prod and prod) |
| Pointers | `/finrisk/<env>/model`, `/finrisk/<env>/index`: created here as `{"version": null}` with `ignore_changes = [value]`, then **owned by finrisk-ml / finrisk-knowledge**. The model pointer now says which **endpoint** serves the version (`{"version": 3, "serving": "endpoint", "endpoint": "finrisk-prod-fraud", ...}`) |
| Written by finrisk-app | `/finrisk/<env>/app_url` |

## What is new in week 13b, and why

The model block moved from "a GitHub job trains a file" to the full lifecycle on SageMaker AI. This repository builds the ground it
stands on:

* **Feature Store + Athena**: the history (PaySim days 1-17, ~6.0 M rows) lives in one offline Feature Store group; labels are a plain
  Glue table; the training set is one point-in-time Athena query. The backfill costs **about USD 8.5 once per account** (BatchWriteRecord,
  ~1.4 USD per million records, Sydney). Nothing in Terraform writes records; destroying the group does not delete them.
* **MLflow App** (serverless, no extra charge): every training, evaluation and monitor run is logged and compared in one UI.
* **Endpoints instead of a model file in the app**: each environment has an endpoint role and the app a permission to call exactly
  its own endpoint. dev and sit are serverless; pre-prod and prod are real-time with Data Capture and blue/green updates guarded by
  alarms.
* **Our own monitor**: SageMaker Model Monitor and Clarify are **closed to new customers since 30 July 2026**, so drift and live quality
  are computed by a job of ours (finrisk-ml) and published as plain CloudWatch metrics (`FinRisk/Model`, dimension `Env=prod`). The
  three prod alarms and one EventBridge rule turn those numbers into "start the training pipeline". The gate and the human approval still
  stand between a retrained model and prod.
* **Schedules in AWS, not GitHub**: the weekly retrain and the (off by default) hourly monitor are EventBridge Scheduler schedules.
* **Studio** (optional): the page where the class *sees* the pipeline graph, registry, model cards and endpoints.

### Things to know before you apply
* **The instructor re-applies `bootstrap/` by hand once** (README steps 2-3, `terraform apply` in `bootstrap/`).
  Policies changed. `terraform plan` must show **roles updated in place (the ml-train, ml-approve, ml-promote x4, infra-plan, infra-drift,
  infra-apply-shared and infra-apply-<env> x4 policies) and exactly 1 role + 1 policy added** (`finrisk-ml-feedback`); nothing destroyed;
  trust policies unchanged. Then run `github_bootstrap.sh ... --apply` again: it creates the Environment `simulation` in finrisk-ml with its
  `AWS_ROLE_ARN` secret. Do this **before** `infra-deliver` runs: the apply roles need the new permissions.
* **Studio needs the account's default VPC.** No default VPC: set `create_studio_domain = false` (everything else works). If creating the
  first domain fails with a service-linked-role error, create the role once as an admin (`aws iam create-service-linked-role
  --aws-service-name sagemaker.amazonaws.com`; "has been taken" means it exists). No pipeline role may create service-linked roles.
* **The two pipelines are not Terraform's.** A schedule or the rule that fires before finrisk-ml has created `finrisk-train` /
  `finrisk-monitor` simply fails to start a run. The rule cannot copy the alarm's name into the pipeline parameter (the SageMaker target
  takes fixed values), so `TriggerReason` is the word `drift`; finrisk-ml asks CloudWatch which alarm is firing.

## The IAM roles (all created in `bootstrap/`)

Every role trusts **one** GitHub token: `aud = sts.amazonaws.com` and an **exact** `sub`. No wildcard anywhere. A `sub` is the
repository's **prefix** plus a **suffix** that names the job. For a repository created after 15 July 2026 the prefix is the
immutable form `repo:<org>@<org id>/<repo>@<repo id>` (read from GitHub by `scripts/oidc_subjects.sh`, passed in as
`sub_prefixes`); for an older repository it is the classic `repo:<org>/<repo>`.

| Role | Who may become it (the suffix after the repository's prefix and `:`) | May do (by name) |
| --- | --- | --- |
| `finrisk-infra-plan` | `finrisk-infra` `pull_request` | read state, Describe/Get/List. Nothing else |
| `finrisk-infra-drift` | `finrisk-infra` `ref:refs/heads/main` | the same read-only policy, for the nightly run (added: a schedule has no `pull_request` sub) |
| `finrisk-infra-apply-shared` | `finrisk-infra` `environment:infra-shared` | state `infra/shared.tfstate`; the two ECR repos, ML + KB buckets, the five roles `finrisk-sagemaker-exec` / `-mlflow` / `-studio` / `-scheduler` / `-events` (each passed to its own service only), the model group, Feature Store group, MLflow App, Studio domain + profile, Glue `finrisk_ml`, Athena `finrisk`, Scheduler group `finrisk`, rule `finrisk-retrain-on-drift`, `/finrisk/shared/*` |
| `finrisk-infra-apply-<env>` x4 | `finrisk-infra` `environment:infra-<env>` | state `env:/<env>/infra/env.tfstate`; the env bucket, `/app/finrisk-<env>` log group, roles `finrisk-<env>-*` (runtime, endpoint, ECS), alarms `finrisk-<env>-*`, `/finrisk/<env>/*`; read `/finrisk/shared/*` |
| `finrisk-app-build` | `finrisk-app` `ref:refs/heads/main` | ECR push to `finrisk-app` only |
| `finrisk-app-deploy-<env>` x4 | `finrisk-app` `environment:<env>` | state `env:/<env>/app/service.tfstate`; Lambda / Express `finrisk-<env>`; PassRole `finrisk-<env>-*`; ECR read; SSM get `/finrisk/shared/*` + `/finrisk/<env>/*`; put `/finrisk/<env>/app_url` |
| `finrisk-ml-train` | `finrisk-ml` `environment:ml` | push `finrisk-train`; pull `finrisk-app`; create/update/start/follow/stop the pipelines `finrisk-train` and `finrisk-monitor` (and their executions); the backfill Processing job `finrisk-backfill-*`; read the registry; PassRole `finrisk-sagemaker-exec`; ML bucket `data/` get+put, `metrics/` get+put, `models/` `datasets/` `monitoring/` and the backfill report get; `DescribeAlarms` `finrisk-prod-model-*`; open the MLflow UI; SSM get `/finrisk/prod/model` + `/finrisk/shared/*`. **No** training jobs or registering of its own (the pipeline does that with the execution role) and never approve |
| `finrisk-ml-approve` | `finrisk-ml` `environment:model-approval` | `UpdateModelPackage` (approval status **and** the model card inside the package) / Describe / List on the group. Nothing else |
| `finrisk-ml-promote-<env>` x4 | `finrisk-ml` `environment:<env>` | registry read; create/delete model + endpoint config, create/update/describe/delete/invoke the endpoint, **all named `finrisk-<env>-fraud...`**; PassRole only `finrisk-<env>-endpoint`; `DescribeAlarms` `finrisk-<env>-endpoint-*`; SSM get+put `/finrisk/<env>/model`; get `/finrisk/<env>/app_url`, `/finrisk/<env>/endpoint_role_arn`, `/finrisk/shared/*` |
| `finrisk-ml-feedback` | `finrisk-ml` `environment:simulation` | the simulated customers and analysts: S3 get `replay/*`, put `labels/source=feedback/*`; `BatchWriteRecord` / `PutRecord` / `DescribeFeatureGroup` on `finrisk-transactions`; SSM get `/finrisk/prod/app_url` + `/finrisk/shared/*`. **No** `models/`, no endpoint, no registry, no pointer |
| `finrisk-kb-build` | `finrisk-knowledge` `ref:refs/heads/main` | KB bucket `indexes/*` get+put + list; `bedrock:InvokeModel` Titan embeddings; SSM get `/finrisk/prod/index` |
| `finrisk-kb-promote-<env>` x4 | `finrisk-knowledge` `environment:<env>` | KB bucket `indexes/*` get + list; SSM get+put `/finrisk/<env>/index`; get `/finrisk/<env>/app_url` |

The environment runtime role (`finrisk-<env>-runtime`, made by `envs/`) is what the *running service* wears: its own log group
and bucket, `models/*` of the ML bucket and `indexes/*` of the KB bucket (read), `bedrock:InvokeModel` on `deepseek.v3.2` and
`amazon.titan-embed-text-v2:0` in the Region, `ssm:GetParameter` on `/finrisk/<env>/*` and `/finrisk/shared/*`, and
`sagemaker:InvokeEndpoint` + `DescribeEndpoint` on `endpoint/finrisk-<env>-fraud` (its own, no other).

The **endpoint role** (`finrisk-<env>-endpoint`, made by `envs/`, worn by SageMaker) pulls `finrisk-train`, reads `models/*`, writes its
own log group `/aws/sagemaker/Endpoints/finrisk-<env>-fraud` and, in pre-prod and prod only, `capture/<env>/*`. The **SageMaker
execution role** (`finrisk-sagemaker-exec`, made by `shared/`) is now the identity of the pipelines, their jobs and the Feature
Store: jobs named `finrisk-*`, the model group, the folders of the ML bucket (read: all; write: all except `data/` and `capture/`; **no
delete**), Athena workgroup `finrisk`, Glue `finrisk_ml`, `PutMetricData` into three namespaces only, and `sagemaker:CallMlflowAppApi`
(the action prefix for an MLflow **App** is `sagemaker:`; `sagemaker-mlflow:` belongs to the older tracking servers).

### What is broad, and why
The header of `bootstrap/oidc.tf` lists every exception in full. New in 13b: the Studio domain, user profile and MLflow App have ids AWS
chooses, so `apply-shared` (and the read-only roles, and `ml-train` for the MLflow UI) name them by pattern (`domain/*`, `user-profile/*`,
`mlflow-app/*`). In short: `ecr:GetAuthorizationToken` on `*` (AWS has no resource
for "log in to ECR"); read-only Describe/List calls on `*` that Terraform's refresh makes; `s3:Get*`/`List*` on a bucket (its
*settings*, not its files); `lambda:*` but only on the function `finrisk-<env>`; ECS Express `cluster/*` and `task-definition/*`
(AWS names them); and the apply roles can write IAM roles named `finrisk-<env>-*`. The guard for that last one is the pipeline
itself: only code on `main`, through an Environment with a reviewer where it matters, ever runs with those roles.
`ecr:SetRepositoryPolicy` / `DeleteRepositoryPolicy` belong to `finrisk-infra-apply-shared` alone (on the two repositories); the app deploy
roles can only *read* the repository policy, which is why `shared/ecr.tf` writes Lambda's pull statement for them.
`iam:CreateServiceLinkedRole` is deliberately **not** granted anywhere.
`finrisk-sagemaker-exec` may create, describe, stop and tag processing, training and tuning jobs of **any** name in the account
and Region: SageMaker Pipelines names the jobs it starts itself (`pipelines-<execution id>-BuildDataset-<random>`), so a
`finrisk-*` rule refused the very first live pipeline run (20 Oct 2026). Only SageMaker can assume that role, and only
`finrisk-ml-train` may start the two pipelines.

## Secrets, variables and required checks (set by `scripts/github_bootstrap.sh`)

One naming rule for all four repositories: **a job with `environment:` reads `secrets.AWS_ROLE_ARN`** (an *Environment* secret
holding that Environment's role); a job without an environment reads a *repository* secret named after its role. Values that
contain the account id are secrets (the repositories are public, and GitHub hides secrets in logs); the rest are variables.

| Repository | Repository variables | Repository secrets | Environments (secret `AWS_ROLE_ARN` in each) | Required checks (ruleset `protect-main`) |
| --- | --- | --- | --- | --- |
| finrisk-infra | `AWS_REGION` | `TF_STATE_BUCKET` `AWS_PLAN_ROLE_ARN` `AWS_DRIFT_ROLE_ARN` | `infra-shared` (R) `infra-dev` `infra-sit` `infra-pre-prod` (R) `infra-prod` (R) | `plan` `terraform-checks` |
| finrisk-app | `AWS_REGION` | `TF_STATE_BUCKET` `AWS_BUILD_ROLE_ARN` `ECR_REPOSITORY` | `dev` `sit` `pre-prod` (R) `prod` (R) | `test` `terraform` |
| finrisk-ml | `AWS_REGION` | (none: the ML names come from SSM `/finrisk/shared/*`) | `ml` `model-approval` (R) `dev` `sit` `pre-prod` (R) `prod` (R) `simulation` | `test` |
| finrisk-knowledge | `AWS_REGION` | `KB_BUCKET` `AWS_KB_BUILD_ROLE_ARN` | `dev` `sit` `pre-prod` (R) `prod` (R) | `kb-check` |

(R) = a required reviewer (you; self-review is allowed because the course is a one-person organisation). `simulation` has none on purpose: it is the replay of customer traffic. Every Environment
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

**1. Create the four EMPTY public repositories** (no README, no license: nothing to push yet). They come first on purpose: since
15 July 2026 GitHub gives every new repository an *immutable subject*, a `sub` that carries the numeric ids of the organisation and
of the repository (`repo:fraud-detection-app@343247080/finrisk-infra@1422750317:...`), and there is no setting to switch that off.
Our roles trust the **exact** `sub` (no wildcard), so they need those ids, and a repository has its ids only after it exists.
(Why GitHub did it: a name can be reused by an attacker after you delete a repository; an id never is.)

```bash
for r in finrisk-infra finrisk-app finrisk-ml finrisk-knowledge; do gh repo create fraud-detection-app/$r --public; done
```

**2. Read the subject prefixes into `bootstrap/`.** Bootstrap runs where it is, in `bootstrap/` of this repository. Its state is
**local**, because it creates the bucket the other stacks keep their state in: `bootstrap/terraform.tfstate` is your only record of
these resources, so keep it until the teardown (it is git-ignored, like `oidc_subjects.auto.tfvars.json`). The script only *reads*
GitHub (four GET calls) and writes `oidc_subjects.auto.tfvars.json`, which Terraform loads by itself:

```bash
bash scripts/oidc_subjects.sh fraud-detection-app --out bootstrap
```

**3. Bootstrap (by hand, once).**

```bash
cd bootstrap
export TF_PLUGIN_CACHE_DIR=~/.terraform.d/plugin-cache; mkdir -p "$TF_PLUGIN_CACHE_DIR"
terraform init
terraform plan          # read it: 24 roles, 24 policies, 1 provider, 1 bucket (+ its settings). In each role's trust policy
                        # look for the `sub`: it must read repo:fraud-detection-app@<id>/finrisk-...@<id>:<job>
terraform apply         # -var create_oidc_provider=false if week 13a's practice repo already made the GitHub provider
```

If you delete and re-create a repository, or rename the organisation, its ids change: run `oidc_subjects.sh` again and
`terraform apply` again (24 roles updated in place), or the job fails with *Not authorized to perform sts:AssumeRoleWithWebIdentity*.

**4. Push the first commit of each repository** into the empty repository (`git remote add origin ...`, `git push -u origin main`).
(`protect-main` blocks direct pushes, so push *before* step 5. Each repository's first workflow run will fail because its secrets do
not exist yet: ignore it.)

**5. Configure GitHub from the outputs.** A dry run first (it prints every command, account ids hidden, and calls nothing):

```bash
bash scripts/github_bootstrap.sh fraud-detection-app            # reads the outputs of bootstrap/
bash scripts/github_bootstrap.sh fraud-detection-app --apply
```

It sets variables, secrets, Environments (reviewers, `main`-only branch policy), the Environment secrets and the rulesets for
all four repositories. Safe to repeat. (`terraform output -json` prints the secret values: never paste its output anywhere.)

**6. First delivery.** Actions -> `infra-deliver` -> *Run workflow*. It applies `shared`, then each environment; approve the
Environments with a reviewer when GitHub asks. When it is green, the other three repositories can run.

**7. From now on** every change is a pull request: read the `plan` summary, merge, watch the stages.

## What it costs (the model block, Sydney; the rest of the course is unchanged)

| Item | Estimate |
| --- | --- |
| Feature Store **backfill** of ~6.0 M history records (`BatchWriteRecord`, 1 write unit each) | **~USD 8.5, once per account** (`history_days` in finrisk-ml can shrink it) |
| Backfill Processing job (`ml.m5.xlarge`, 30-60 min) | ~USD 0.15-0.30 |
| One training pipeline run (dataset + 8 tuning jobs + evaluate) | ~USD 0.25-0.35 (the weekly schedule runs one every Monday: set `weekly_retrain_enabled = false` after class) |
| pre-prod + prod real-time endpoints (`ml.t2.medium`), ~3 h | ~USD 0.45; **they bill until deleted**: finrisk-ml `teardown.yml` first |
| Serverless endpoints, MLflow, Athena, Scheduler, alarms, Studio (EFS bytes) | cents |

## Tests

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
bash scripts/tf_checks.sh               # fmt, validate, terraform test (mock provider) for bootstrap, shared, envs
.venv/bin/python -m pytest -q           # scripts, workflows, lock files; add -m "not terraform" to skip the Terraform runs
```

`tf_checks.sh` works in a temporary copy, so nothing lands in your checkout (the copy leaves out `*.tfstate*`, the saved `plan`, `.env` and `.terraform/`). The `terraform test` files prove, with a *mock* AWS
provider (no account needed): every role trusts exactly one repository and one subject (classic or immutable, never a wildcard, never another repository's); the plan role cannot change anything; no
role names another environment; the SSM names are the contract's; the pointers ignore value changes; the workspace guard works. Week 13b added: the 24 roles; the feedback role
cannot touch `models/` or a pointer; a promote role names only its own environment's endpoint and passes only its own endpoint role; the
alarm names and thresholds; the hourly monitor is off by default; the ML bucket never expires `raw/`, `labels/`, `feature-store/` or `replay/`;
the Feature Store group, tables, workgroup, MLflow App, schedules, rule and Studio domain are what the design says.

## Drift, in one paragraph
`drift` runs a read-only plan for each scope every night. Exit code 2 means the real AWS differs from the code: the job fails and
the summary lists the addresses, under "Changed outside Terraform" when somebody edited a resource by hand. Fix it by reverting
the click, or by changing the code and merging. (GitHub turns scheduled workflows off after 60 days without a push to a public
repository: press "Enable workflow" if the nightly run stops.)

## Teardown (reverse order, by an admin, from your laptop)
0. finrisk-ml `teardown.yml` for each environment (endpoints, endpoint configs, models: **they bill by the hour**). Then, as an admin, the
   things finrisk-ml made that Terraform does not own: delete the pipelines (`aws sagemaker delete-pipeline --pipeline-name finrisk-train`
   and `finrisk-monitor`, with a client request token), every model package **version** in `finrisk-fraud-model` (the group cannot be
   deleted while it has versions), any model cards, and any Studio spaces/apps students opened (the domain cannot be deleted while it
   has apps). The Feature Store files and Athena results are objects in the ML bucket: they go in step 3.
1. finrisk-app `teardown` for each environment (the compute), and delete the model/index pointers' consumers.
2. `envs/`, one workspace at a time: `terraform init -backend-config=...` (the same flags as `scripts/tf.sh`), `terraform workspace
   select <env>`, `terraform destroy -var-file=<env>.tfvars`. pre-prod and prod buckets must be emptied first (every object *version*).
3. `shared/`: empty the ML and KB buckets (every version, including `feature-store/`, `athena/`, `capture/`), then `terraform destroy` (the ECR
   repos are deleted with their images; the Studio user profile then the domain, the schedules, the rule, the MLflow App, the Feature Store
   group, the workgroup and the Glue database go in dependency order). `bash scripts/sweep.sh` must end with `TOTAL 0 left`.
4. `bootstrap/`: empty the state bucket last (every version), then `terraform destroy` in `bootstrap/`.

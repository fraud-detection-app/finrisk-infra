# WHERE Terraform keeps this folder's state: the S3 bucket that ../bootstrap created.
#
# A PARTIAL backend: "use S3" is written here, the details (bucket, key, region) are not. They differ per account,
# so scripts/tf.sh passes them at init time:
#
#   terraform init -backend-config="bucket=<state bucket>" -backend-config="key=infra/shared.tfstate" \
#                  -backend-config="region=ap-southeast-2" -backend-config="use_lockfile=true" -backend-config="encrypt=true"
#
# shared/ uses the DEFAULT workspace, so its state is the object infra/shared.tfstate.
# (scripts/tf_checks.sh deletes this file in a temporary copy, so the offline tests use local state.)

terraform {
  backend "s3" {}
}

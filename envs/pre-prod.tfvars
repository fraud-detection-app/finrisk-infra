# pre-prod -- rehearsal; prod-like: ECS Express Mode, versioned data.
# Run:  terraform workspace select -or-create pre-prod
#       terraform apply -var-file=pre-prod.tfvars

env                = "pre-prod"
compute            = "ecs"
log_retention_days = 30
bucket_versioning  = true

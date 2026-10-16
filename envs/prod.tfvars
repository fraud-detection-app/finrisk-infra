# prod -- real users; ECS Express Mode, versioned data, longest log retention.
# Run:  terraform workspace select -or-create prod
#       terraform apply -var-file=prod.tfvars

env                = "prod"
compute            = "ecs"
log_retention_days = 90
bucket_versioning  = true

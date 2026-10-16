# dev -- developers try things; Lambda scales to zero.
# Run:  terraform workspace select -or-create dev
#       terraform apply -var-file=dev.tfvars

env                = "dev"
compute            = "lambda"
log_retention_days = 7
bucket_versioning  = false

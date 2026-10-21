# sit -- system integration tests; same Lambda compute as dev.
# Run:  terraform workspace select -or-create sit
#       terraform apply -var-file=sit.tfvars

env                = "sit"
compute            = "lambda"
log_retention_days = 14
bucket_versioning  = false

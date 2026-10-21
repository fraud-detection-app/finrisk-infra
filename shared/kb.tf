# The home of the KNOWLEDGE BASE index, shared by all four environments.
#
# finrisk-knowledge builds a search index from its markdown documents and publishes it as a NEW folder every time:
#
#   s3://<kb bucket>/indexes/<version>/manifest.json  chunks.jsonl  embeddings.npy
#
# A published index is never overwritten, so a rollback is "point the environment at the old folder". Each
# environment's pointer (/finrisk/<env>/index) says which folder it serves; the service hot-reloads when it changes.
#
# !! No force_destroy, like the ML bucket: empty it by hand (every object VERSION) and then destroy.
resource "aws_s3_bucket" "kb" {
  bucket           = local.kb_bucket_name
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket_versioning" "kb" {
  bucket = aws_s3_bucket.kb.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "kb" {
  bucket = aws_s3_bucket.kb.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "kb" {
  bucket = aws_s3_bucket.kb.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.kb]
}

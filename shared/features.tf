# The DATA PLATFORM of the model block (week 13b): where the history lives and how it is asked about.
#
#   S3 raw/ ──backfill job──► Feature Store group finrisk-transactions  (offline store: parquet in feature-store/ + Glue table
#                             `finrisk_ml.transactions`, which the Feature Store creates)
#   S3 labels/  ◄──────────── Glue table `finrisk_ml.labels`           (made here: a plain table over a folder)
#   Athena workgroup finrisk  asks both: the training set is ONE point-in-time query that joins them (finrisk-ml pipeline/queries.py)
#
# The group is OFFLINE only (decision): no online store, so nothing runs and nothing bills per hour. Records are written with
# BatchWriteRecord (about USD 1.4 per MILLION records, Sydney: the backfill of ~6.0 M history rows is ~USD 8.5, ONCE per
# account). The labels are a plain table, not a second feature group: no second bill.
#
# Terraform owns the group's DEFINITION. The records in it, and the files under feature-store/, are data: destroying the group
# does not delete them (empty the bucket by hand, as README.md says).

# ---------------------------------------------------------------- Glue database and the labels table
resource "aws_glue_catalog_database" "ml" {
  name        = local.glue_database
  description = "finrisk ML data: the Feature Store's offline table (transactions) and the labels table."
}

# What REALLY happened to each transaction, and when we learned it. Written as parquet by the backfill (source=history) and by
# the feedback step (source=feedback). The folders under labels/ (source=..., batch=...) are folders only, NOT partition keys:
# Athena reads every file under the location.
resource "aws_glue_catalog_table" "labels" {
  name          = local.labels_table
  database_name = aws_glue_catalog_database.ml.name
  description   = "Ground truth per transaction: row_id, is_fraud, event_time, label_time (when the analysts knew), source, batch_id."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL       = "TRUE"
    classification = "parquet"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.ml.bucket}/labels/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters            = { "serialization.format" = "1" }
    }

    columns {
      name = "row_id"
      type = "string"
    }
    columns {
      name = "is_fraud"
      type = "int"
    }
    columns {
      name = "event_time"
      type = "string"
    }
    columns {
      name = "label_time"
      type = "string"
    }
    columns {
      name = "source"
      type = "string"
    }
    columns {
      name = "batch_id"
      type = "string"
    }
  }
}

# ---------------------------------------------------------------- the Feature Store group
# The feature definitions are the CONTRACT with finrisk-app's FEATURE_COLUMNS (same names, same order). `hour_of_day` replaces
# the old `step`: a time index always drifts; the hour of the day is a real, stable signal. `step` stays as metadata.
locals {
  # name -> Feature Store type. String / Integral / Fractional are SageMaker's three.
  feature_definitions = [
    { name = "row_id", type = "String" },
    { name = "event_time", type = "String" }, # ISO-8601 UTC: 2026-09-01T00:00:00Z + (step - 1) hours
    { name = "step", type = "Integral" },
    { name = "transaction_type", type = "String" },
    { name = "origin_customer", type = "String" },
    { name = "amount", type = "Fractional" },
    { name = "log_amount", type = "Fractional" },
    { name = "origin_old_balance", type = "Fractional" },
    { name = "origin_new_balance", type = "Fractional" },
    { name = "destination_old_balance", type = "Fractional" },
    { name = "destination_new_balance", type = "Fractional" },
    { name = "origin_balance_delta", type = "Fractional" },
    { name = "destination_balance_delta", type = "Fractional" },
    { name = "amount_to_origin_balance", type = "Fractional" },
    { name = "hour_of_day", type = "Integral" },
    { name = "tx_index_for_origin", type = "Integral" },
    { name = "customer_tx_count_so_far", type = "Integral" },
    { name = "customer_amount_so_far", type = "Fractional" },
  ]
}

resource "aws_sagemaker_feature_group" "transactions" {
  feature_group_name             = local.feature_group
  description                    = "One row per PaySim transaction: the model's features, as they were when the transaction happened."
  record_identifier_feature_name = "row_id"
  event_time_feature_name        = "event_time"

  # The role the Feature Store writes the offline files (and creates the Glue table) with.
  role_arn = aws_iam_role.sagemaker_exec.arn

  dynamic "feature_definition" {
    for_each = local.feature_definitions

    content {
      feature_name = feature_definition.value.name
      feature_type = feature_definition.value.type
    }
  }

  # OFFLINE only: there is no online_store_config block, so no online store exists.
  offline_store_config {
    table_format = "Glue"

    s3_storage_config {
      s3_uri = "s3://${aws_s3_bucket.ml.bucket}/feature-store/"
    }

    # Set explicitly, so the names in the queries are fixed: finrisk_ml.transactions
    data_catalog_config {
      catalog    = "AwsDataCatalog"
      database   = aws_glue_catalog_database.ml.name
      table_name = local.features_table
    }
  }

  depends_on = [aws_iam_role_policy.sagemaker_exec]
}

# ---------------------------------------------------------------- the Athena workgroup
# A workgroup is Athena's "settings and budget" for a set of queries. ENFORCED means the workgroup's settings win over whatever a
# query asks for: results always go to athena/ of the ML bucket (the one place the roles may write them), and a query that would
# scan more than the cutoff is stopped before it bills.
resource "aws_athena_workgroup" "finrisk" {
  name        = local.workgroup
  description = "finrisk model queries: the point-in-time training set, the monitor's label join."

  # `terraform destroy` must not fail on leftover query history: results are in the bucket, not here.
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff

    result_configuration {
      output_location = "s3://${aws_s3_bucket.ml.bucket}/athena/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

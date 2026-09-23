# =============================================================================
# DynamoDB Module — main.tf
# The application's only persistent store: one table for todos.
#
# Design notes:
#   - PAY_PER_REQUEST: a portfolio workload with one or two concurrent users
#     cannot justify provisioned capacity, and provisioned capacity is the
#     single most common source of unexpected DynamoDB bills.
#   - Single hash key "pk": the todo id is the only query pattern the app has
#     (get by id, scan for the list). Adding a sort key or a GSI for a query
#     nobody runs would be speculative; a Scan is the honest expression of
#     "list every todo" at this scale.
#   - No TTL: rows are removed explicitly by the user, never by expiry.
#   - Deletion protection + PITR: the table holds user data, so both are on.
#     Deleting the table is a deliberate two-step (Terraform change + explicit
#     UpdateDeletionProtection call), never a side effect of a bad apply.
# =============================================================================

resource "aws_dynamodb_table" "todos" {
  name         = "${var.project_name}-todos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  # Encrypted with the project CMK, not the AWS-owned default key, so key usage
  # is auditable and rotation is under this repo's control.
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  # Continuous backups with a 35-day window (AWS default) — a bad Jenkins
  # release can write rows, and a task-definition rollback does not undo them.
  point_in_time_recovery {
    enabled = true
  }

  # Refuse to drop the table on a stray `terraform destroy` of the stack.
  deletion_protection_enabled = true

  tags = {
    Name = "${var.project_name}-todos"
  }
}

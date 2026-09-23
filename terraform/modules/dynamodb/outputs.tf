# =============================================================================
# DynamoDB Module — outputs.tf
# Exported values from the DynamoDB module.
# =============================================================================

output "table_name" {
  description = "Name of the todos table — passed to the ECS task as TODO_TABLE"
  value       = aws_dynamodb_table.todos.name
}

output "table_arn" {
  description = "ARN of the todos table — used to scope the ECS task role's DynamoDB permissions"
  value       = aws_dynamodb_table.todos.arn
}

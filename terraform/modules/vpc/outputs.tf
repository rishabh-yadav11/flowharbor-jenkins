# =============================================================================
# VPC Module — outputs.tf
# =============================================================================
# Exported values from the VPC module that other modules consume.
# =============================================================================

output "vpc_id" {
  description = "The ID of the created VPC (e.g., vpc-0a1b2c3d4e5f67890)"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (one per AZ) for ALB and NAT Gateway placement"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (one per AZ) for Jenkins instances and ECS tasks"
  value       = aws_subnet.private[*].id
}

output "private_subnet_cidrs" {
  description = "List of private subnet CIDR blocks for security group ingress rules"
  value       = aws_subnet.private[*].cidr_block
}

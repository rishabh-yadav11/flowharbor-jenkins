# =============================================================================
# Security Groups Module — variables.tf
# =============================================================================
# Input variables for the security groups module.
# =============================================================================

variable "vpc_id" {
  description = "ID of the VPC where all security groups will be created"
  type        = string
}

variable "project_name" {
  description = "Project name used as a prefix for security group naming and tagging"
  type        = string
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks of private subnets (reserved for future use, e.g., allowing internal traffic between private resources)"
  type        = list(string)
}

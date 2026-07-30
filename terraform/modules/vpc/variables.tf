# =============================================================================
# VPC Module — variables.tf
# =============================================================================
# Input variables required by the VPC module.
# =============================================================================

variable "aws_region" {
  description = "AWS region used to construct VPC endpoint service names (e.g., com.amazonaws.ap-south-1.s3)"
  type        = string
}

variable "azs" {
  description = "List of availability zone names to create subnets in (e.g., ['ap-south-1a', 'ap-south-1b'])"
  type        = list(string)
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g., '10.0.0.0/16'). Subnet CIDRs are derived from this using cidrsubnet()."
  type        = string
}

variable "project_name" {
  description = "Project name used as a prefix for tagging all VPC resources"
  type        = string
}

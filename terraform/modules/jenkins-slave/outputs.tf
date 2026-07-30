# =============================================================================
# Jenkins Slave Module — outputs.tf
# =============================================================================
# Exported values from the Jenkins Slave module.
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID of the Jenkins Slave — useful for SSM Session Manager or troubleshooting"
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Private IP address of the Jenkins Slave — useful for diagnostics (the Master connects via JNLP, not direct IP)"
  value       = aws_instance.this.private_ip
}

# =============================================================================
# Jenkins Master Module — outputs.tf
# =============================================================================
# Exported values from the Jenkins Master module.
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID of the Jenkins Master — useful for SSM Session Manager or AWS console access"
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Private IP address of the Jenkins Master — used by the ALB target group attachment"
  value       = aws_instance.this.private_ip
}

output "jenkins_url" {
  description = "Internal Jenkins URL (private IP + port 8080) — not publicly accessible, goes through ALB"
  value       = "http://${aws_instance.this.private_ip}:8080"
}

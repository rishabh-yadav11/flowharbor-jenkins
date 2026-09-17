# =============================================================================
# WAF Module — variables.tf
# =============================================================================
# Input variables for the WAF module (issue #4).
# =============================================================================

variable "project_name" {
  description = "Project name used for WAF resource naming"
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB the Web ACL is associated with"
  type        = string
}

variable "domain_name" {
  description = "Root domain name used to build the Jenkins hostname (jenkins.<domain>)"
  type        = string
}

variable "jenkins_allowed_ipv4_cidrs" {
  description = "IPv4 CIDRs allowed to reach jenkins.<domain> through the WAF. Empty (default) denies all internet traffic to Jenkins until office/VPN egress CIDRs are set — this is the secure default for issue #4."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.jenkins_allowed_ipv4_cidrs : can(cidrhost(c, 0))])
    error_message = "Each entry in jenkins_allowed_ipv4_cidrs must be a valid IPv4 CIDR (e.g., \"203.0.113.0/24\")."
  }
}

variable "jenkins_login_rate_limit" {
  description = "Max requests per 5 minutes per IP to jenkins.<domain>/login before WAF rate-blocks (AWS minimum is 100)"
  type        = number
  default     = 100

  validation {
    condition     = var.jenkins_login_rate_limit >= 100 && var.jenkins_login_rate_limit <= 20000
    error_message = "jenkins_login_rate_limit must be between 100 and 20000."
  }
}

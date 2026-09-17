# =============================================================================
# WAF Module — main.tf
# =============================================================================
# Issue #4: Jenkins was reachable from 0.0.0.0/0 on the shared public ALB
# (jenkins.<domain> → ALB:443 → 8080) with no WAF, no IP allowlist and no
# rate limiting on /login.
#
# This module attaches a REGIONAL WAFv2 Web ACL to the single shared ALB.
# A dedicated internal ALB would also fix this but is a larger migration
# (new LB, DNS, SG split); the WAF allowlist achieves the same L7 outcome
# without breaking testing/staging/prod on the shared ALB.
#
# Rules (evaluated in priority order):
#   0  jenkins-ip-guard          — Host == jenkins.<domain> AND source IP NOT
#                                  in allowlist → 403. Empty allowlist denies
#                                  all (secure default).
#   10 jenkins-login-rate-limit   — rate-blocks IPs hammering
#                                  jenkins.<domain>/login (brute-force guard).
#   20 AWSManagedRulesCommonRuleSet
#   30 AWSManagedRulesKnownBadInputsRuleSet
#
# Default action is allow so non-Jenkins hosts (testing/staging/prod) keep
# working unchanged.
# =============================================================================

# ---- Jenkins Allowlist -------------------------------------------------------
# Office/VPN egress CIDRs permitted to reach Jenkins. Empty = deny all.
resource "aws_wafv2_ip_set" "jenkins_allowlist" {
  name               = "${var.project_name}-jenkins-allowlist"
  description        = "Allowlist for jenkins.${var.domain_name} (issue #4)"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.jenkins_allowed_ipv4_cidrs

  tags = {
    Name = "${var.project_name}-jenkins-allowlist"
  }
}

# ---- Web ACL -----------------------------------------------------------------
resource "aws_wafv2_web_acl" "this" {
  name        = "${var.project_name}-alb-waf"
  description = "Shared-ALB WAF: Jenkins IP allowlist + /login rate limit + AWS managed rules (issue #4)"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-alb-waf"
    sampled_requests_enabled   = true
  }

  # -- Priority 0: Jenkins IP guard --------------------------------------------
  rule {
    name     = "jenkins-ip-guard"
    priority = 0

    action {
      block {
        custom_response {
          response_code = 403
        }
      }
    }

    statement {
      and_statement {
        statement {
          byte_match_statement {
            search_string         = "jenkins.${var.domain_name}"
            positional_constraint = "EXACTLY"
            field_to_match {
              single_header {
                name = "host"
              }
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          not_statement {
            statement {
              ip_set_reference_statement {
                arn = aws_wafv2_ip_set.jenkins_allowlist.arn
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-jenkins-ip-guard"
      sampled_requests_enabled   = true
    }
  }

  # -- Priority 10: Jenkins /login brute-force rate limit -----------------------
  rule {
    name     = "jenkins-login-rate-limit"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.jenkins_login_rate_limit
        aggregate_key_type = "IP"

        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                search_string         = "jenkins.${var.domain_name}"
                positional_constraint = "EXACTLY"
                field_to_match {
                  single_header {
                    name = "host"
                  }
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/login"
                positional_constraint = "CONTAINS"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-jenkins-login-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # -- Priority 20: AWS managed common protections ------------------------------
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-AWSManagedRulesCommon"
      sampled_requests_enabled   = true
    }
  }

  # -- Priority 30: AWS managed known-bad-inputs --------------------------------
  rule {
    name     = "AWSManagedRulesKnownBadInputs"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-AWSManagedRulesBadInputs"
      sampled_requests_enabled   = true
    }
  }

  tags = {
    Name = "${var.project_name}-alb-waf"
  }
}

# ---- ALB Association ----------------------------------------------------------
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

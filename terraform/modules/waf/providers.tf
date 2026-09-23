# =============================================================================
# WAF Module — providers.tf
# This module declares both provider configurations it needs:
#   - aws           (the default instance) for the REGIONAL ACL on the shared ALB
#   - aws.us_east_1 for the CLOUDFRONT-scope ACL, which WAFv2 only accepts in
#                   us-east-1 no matter where the distribution is served from
#
# `configuration_aliases` makes the second instance a REQUIREMENT of this
# module: any caller that forgets to pass it fails at validate time rather than
# silently creating a REGIONAL ACL that CloudFront will not accept.
# =============================================================================

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.0, < 6.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

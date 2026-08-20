# =============================================================================
# CloudFront Module — main.tf
# =============================================================================
# This module creates a CloudFront distribution that serves as a CDN in front
# of the ALB for the production domain (flowharbor.in).
#
# What CloudFront provides:
#   - SSL termination at the edge (closer to users, lower latency)
#   - DDoS protection (AWS Shield Standard included)
#   - Caching of static assets (TTL up to 1 day)
#   - Geographic restriction capabilities (currently unrestricted)
#   - Custom header (X-Origin: cloudfront) to verify requests originate from CF
#
# Only the production domain routes through CloudFront. Dev and staging go
# directly to the ALB.
# =============================================================================

# ---- Origin Request Policy ---------------------------------------------------
# Only the Host header is forwarded to the ALB (required for host-based
# routing). No cookies, no query strings — reduces data exposure compared to
# the previous "forward all cookies and query strings" behavior.
resource "aws_cloudfront_origin_request_policy" "alb" {
  name    = "${var.project_name}-alb-origin-request"
  comment = "Forward only the Host header to the ALB for routing"

  cookies_config {
    cookie_behavior = "none"
  }
  query_strings_config {
    query_string_behavior = "none"
  }
  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Host"]
    }
  }
}

# ---- Cache Policy ------------------------------------------------------------
# Static landing page: cache responses without query strings or cookies in the
# cache key, so users' cookies are never stored or echoed back.
resource "aws_cloudfront_cache_policy" "alb" {
  name    = "${var.project_name}-alb-cache"
  comment = "Cache responses; no cookies or query strings in the cache key"

  default_ttl = 3600
  max_ttl     = 86400
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
  }
}

# ---- CloudFront Distribution ------------------------------------------------
resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "FlowHarbor production distribution"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # Only North America and Europe (cheapest)

  # The production domain (flowharbor.in) is an alias for the distribution.
  aliases = [var.domain_name]

  # ---- Origin: ALB ----------------------------------------------------------
  # Traffic is forwarded to the ALB's DNS name over HTTP (TLS is between
  # viewer and CloudFront, then CloudFront and ALB use HTTP internally).
  # SECURITY NOTE: origin_protocol_policy is "http-only" because the ALB only
  # serves the CloudFront ACM cert regionally; upgrading to https-only would
  # require an ALB listener/TLS setup for the CF↔origin hop. The CF↔ALB path
  # stays inside AWS, so exposure is limited. Review before a production rollout.
  origin {
    domain_name = var.alb_domain_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # CloudFront → ALB over HTTP
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Custom header so the ALB can verify requests come from CloudFront.
    # This prevents bypassing the CDN for production traffic.
    custom_header {
      name  = "X-Origin"
      value = "cloudfront"
    }
  }

  # ---- Default Cache Behavior -----------------------------------------------
  # Controls how CloudFront caches and forwards requests to the origin.
  default_cache_behavior {
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https" # HTTP → HTTPS redirect
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"] # Only cache read requests
    compress               = true            # Gzip/brotli compression

    cache_policy_id          = aws_cloudfront_cache_policy.alb.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.alb.id
  }

  # ---- Viewer Certificate ---------------------------------------------------
  # Use the ACM certificate provisioned in us-east-1.
  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"     # SNI for multiple domains on one IP
    minimum_protocol_version = "TLSv1.2_2021" # Modern TLS minimum
  }

  # ---- Geo Restrictions -----------------------------------------------------
  # No geographic restrictions — the distribution is available worldwide.
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "${var.domain_name}-cloudfront"
  }
}
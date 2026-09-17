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
#   - Custom header (X-Origin-Verify: secret) to verify requests originate from CF
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
  web_acl_id          = var.web_acl_id != "" ? var.web_acl_id : null
  http_version        = "http2and3"

  dynamic "logging_config" {
    for_each = var.logging_bucket_domain != "" ? [1] : []
    content {
      bucket          = var.logging_bucket_domain
      prefix          = var.logging_prefix
      include_cookies = false
    }
  }

  # The production domain (flowharbor.in) is an alias for the distribution.
  aliases = [var.domain_name]

  # ---- Origin: ALB ----------------------------------------------------------
  # Traffic is forwarded to the cert-matched origin hostname
  # (origin.<domain> → ALB alias, covered by the wildcard ACM cert) over
  # HTTPS so the CloudFront↔ALB hop is encrypted and the origin certificate
  # can be validated against a hostname the ALB actually serves. Pass the
  # raw ALB DNS name here will fail TLS verification (ALB serves the
  # flowharbor.in cert, not *.elb.amazonaws.com) — always use the
  # origin.<domain> alias (see route53 module).
  origin {
    domain_name = var.alb_domain_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only" # CloudFront → ALB over TLS
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Secret header the ALB validates on the prod listener rule. This is the
    # L7 origin-bypass guard: requests for flowharbor.in that arrive without
    # this exact header value fall through to the listener default 404.
    # The value is a per-stack secret (TF_VAR), never the guessable
    # literal "cloudfront".
    custom_header {
      name  = var.origin_verify_header
      value = var.origin_verify_value
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
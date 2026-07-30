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

    forwarded_values {
      query_string = true     # Forward query strings to origin
      headers      = ["Host"] # Forward Host header for ALB routing
      cookies {
        forward = "all" # Forward all cookies
      }
    }

    # TTL settings: how long CloudFront caches responses.
    min_ttl     = 0     # Minimum cache time
    default_ttl = 3600  # 1 hour (default)
    max_ttl     = 86400 # 1 day (maximum)
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

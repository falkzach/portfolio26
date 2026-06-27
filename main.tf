terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ==============================================================================
# 1. MULTI-REGION PROVIDER CONFIGURATIONS
# ==============================================================================
provider "aws" {
  region = "us-east-1" # Default region (Handles ACM and CloudFront)
}

provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"
}

# ==============================================================================
# 2. VARIABLES
# ==============================================================================
variable "domain_name" {
  type        = string
  default     = "falkzach.net"
  description = "The absolute target domain name for the portfolio site."
}

variable "bucket_prefix" {
  type        = string
  default     = "falkzach-portfolio-2026-origin"
  description = "Base namespace to ensure globally unique S3 names."
}

# ==============================================================================
# 3. ROUTE 53 HOSTED ZONE
# ==============================================================================
resource "aws_route53_zone" "main" {
  name = "falkzach.net"
}

# ==============================================================================
# 4. ACM CERTIFICATE & AUTOMATED DNS VALIDATION (Requires us-east-1 for CDN)
# ==============================================================================
resource "aws_acm_certificate" "cert" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.main.zone_id
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ==============================================================================
# 5. CLOUDFRONT ORIGIN ACCESS CONTROL (OAC)
# ==============================================================================
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "s3-portfolio-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ==============================================================================
# 6. DUAL-REGION STORAGE AND ASSET DEPLOYMENT (S3)
# ==============================================================================

# --- REGION 1: us-east-1 ---
resource "aws_s3_bucket" "east_1" {
  bucket        = "${var.bucket_prefix}-us-east-1"
  force_destroy = true
}
resource "aws_s3_bucket_public_access_block" "east_1" {
  bucket                  = aws_s3_bucket.east_1.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_object" "html_east_1" {
  bucket       = aws_s3_bucket.east_1.id
  key          = "index.html"
  source       = "index.html"
  content_type = "text/html"
  etag         = filemd5("index.html")
}

resource "aws_s3_object" "favicon_east_1" {
  bucket       = aws_s3_bucket.east_1.id
  key          = "favicon.ico"
  source       = "favicon.ico"
  content_type = "image/x-icon"
  etag         = filemd5("favicon.ico")
}

# --- REGION 2: us-west-2 ---
resource "aws_s3_bucket" "west_2" {
  provider      = aws.us_west_2
  bucket        = "${var.bucket_prefix}-us-west-2"
  force_destroy = true
}
resource "aws_s3_bucket_public_access_block" "west_2" {
  provider                = aws.us_west_2
  bucket                  = aws_s3_bucket.west_2.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_object" "html_west_2" {
  provider     = aws.us_west_2
  bucket       = aws_s3_bucket.west_2.id
  key          = "index.html"
  source       = "index.html"
  content_type = "text/html"
  etag         = filemd5("index.html")
}

resource "aws_s3_object" "favicon_west_2" {
  provider     = aws.us_west_2
  bucket       = aws_s3_bucket.west_2.id
  key          = "favicon.ico"
  source       = "favicon.ico"
  content_type = "image/x-icon"
  etag         = filemd5("favicon.ico")
}

# ==============================================================================
# 7. EDGE NETWORKING & REGIONAL ORIGIN FAILOVER GROUP (CloudFront)
# ==============================================================================
resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [var.domain_name]

  # Node 1: us-east-1
  origin {
    domain_name              = aws_s3_bucket.east_1.bucket_regional_domain_name
    origin_id                = "s3-us-east-1"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  # Node 2: us-west-2
  origin {
    domain_name              = aws_s3_bucket.west_2.bucket_regional_domain_name
    origin_id                = "s3-us-west-2"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  # High Availability Origin Group Configuration
  origin_group {
    origin_id = "multi-region-origin-group"

    failover_criteria {
      status_codes = [500, 502, 503, 504]
    }

    member { origin_id = "s3-us-east-1" }
    member { origin_id = "s3-us-west-2" }
  }

  default_cache_behavior {
    target_origin_id       = "multi-region-origin-group"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true # Automatically runs Brotli/Gzip down to ~600 bytes

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 31536000
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ==============================================================================
# 8. S3 BUCKET POLICIES (Configured sequentially post-CDN allocation)
# ==============================================================================
data "aws_iam_policy_document" "s3_policy_east_1" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.east_1.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}

data "aws_iam_policy_document" "s3_policy_west_2" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.west_2.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "east_1" {
  bucket = aws_s3_bucket.east_1.id
  policy = data.aws_iam_policy_document.s3_policy_east_1.json
}

resource "aws_s3_bucket_policy" "west_2" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.west_2.id
  policy   = data.aws_iam_policy_document.s3_policy_west_2.json
}

# ==============================================================================
# 9. ROUTE 53 CDN ALIAS ROUTING RECORD
# ==============================================================================
resource "aws_route53_record" "cdn_alias" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

# ==============================================================================
# 10. OUTPUT METRICS FOR PACKET VERIFICATION
# ==============================================================================
output "validation_url" {
  value       = "https://${var.domain_name}"
  description = "Target address for evaluating live wire payload size."
}

output "cloudfront_endpoint" {
  value       = aws_cloudfront_distribution.cdn.domain_name
  description = "Direct canonical domain returned by CloudFront edge."
}

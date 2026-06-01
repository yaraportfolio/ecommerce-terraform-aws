# ============================================================
# MODULE : CloudFront + Route 53 + ACM
# Couvre : section 3 (DNS & CDN) de ARCHITECTURE.md
# ============================================================

# ---- ACM Certificate (doit être en us-east-1 pour CloudFront) ----
resource "aws_acm_certificate" "main" {
  count             = var.domain_name != "" ? 1 : 0
  provider          = aws.us_east_1  # CloudFront exige us-east-1
  domain_name       = var.domain_name
  validation_method = "DNS"
  subject_alternative_names = ["www.${var.domain_name}"]
  lifecycle { create_before_destroy = true }
  tags = { Name = "${var.project}-cert" }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.domain_name != "" ? {
    for dvo in aws_acm_certificate.main[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}
  provider        = aws.us_east_1
  zone_id         = data.aws_route53_zone.main[0].zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  count                   = var.domain_name != "" ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---- Route 53 ----
data "aws_route53_zone" "main" {
  count = var.domain_name != "" ? 1 : 0
  name  = var.domain_name
}

resource "aws_route53_record" "www" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_prefix" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# ---- CloudFront Distribution ----
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = "${var.project} - Frontend e-commerce"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"  # Europe + Amérique du Nord
  aliases             = var.domain_name != "" ? [var.domain_name, "www.${var.domain_name}"] : []

  # Origine : ALB public
  origin {
    origin_id   = "ALB-${var.project}"
    domain_name = var.alb_dns
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Behavior par défaut : frontend React (avec cache)
  default_cache_behavior {
    target_origin_id       = "ALB-${var.project}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]

    # Cache policy : Managed-CachingOptimized
    cache_policy_id          = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcb" # AllViewer

    # SPA fallback : toutes les routes vers index.html
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_redirect.arn
    }
  }

  # Behavior /api/* : pas de cache (forward vers microservices)
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "ALB-${var.project}"
    viewer_protocol_policy = "https-only"
    compress               = false
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]

    # CachingDisabled policy
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcb"
  }

  # Certificat SSL
  viewer_certificate {
    acm_certificate_arn      = var.domain_name != "" ? aws_acm_certificate_validation.main[0].certificate_arn : null
    cloudfront_default_certificate = var.domain_name == ""
    ssl_support_method       = var.domain_name != "" ? "sni-only" : null
    minimum_protocol_version = var.domain_name != "" ? "TLSv1.2_2021" : null
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  tags = { Name = "${var.project}-cloudfront" }

  depends_on = [aws_acm_certificate_validation.main]
}

# Fonction CloudFront : SPA redirect (routes React vers index.html)
resource "aws_cloudfront_function" "spa_redirect" {
  name    = "${var.project}-spa-redirect"
  runtime = "cloudfront-js-2.0"
  comment = "Redirect all non-file requests to index.html for React SPA"
  publish = true
  code    = <<-EOF
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      if (!uri.includes('.') && uri !== '/') {
        request.uri = '/index.html';
      }
      return request;
    }
  EOF
}

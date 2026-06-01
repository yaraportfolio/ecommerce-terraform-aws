output "cloudfront_domain"  { value = aws_cloudfront_distribution.main.domain_name }
output "cloudfront_id"      { value = aws_cloudfront_distribution.main.id }
output "certificate_arn"    { value = var.domain_name != "" ? aws_acm_certificate.main[0].arn : "" }

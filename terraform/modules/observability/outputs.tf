output "dashboard_url"   { value = "https://console.aws.amazon.com/cloudwatch/home#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}" }
output "cloudtrail_s3"   { value = aws_s3_bucket.cloudtrail.bucket }
output "sns_topic_arn"   { value = var.alert_email != "" ? aws_sns_topic.alerts[0].arn : "" }

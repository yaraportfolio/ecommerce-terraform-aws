# ============================================================
# MODULE : Observabilité
# Couvre : section 13 (Observabilité) de ARCHITECTURE.md
# CloudWatch Logs · Metrics · Alarmes · VPC Flow Logs · CloudTrail
# ============================================================

# ---- CloudWatch Log Groups ----
resource "aws_cloudwatch_log_group" "eks_control_plane" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 7
  tags              = { Name = "${var.project}-eks-logs" }
}

resource "aws_cloudwatch_log_group" "microservices" {
  for_each          = toset(["auth-service", "product-service", "order-service", "review-service"])
  name              = "/ecommerce/${each.key}"
  retention_in_days = 7
  tags              = { Name = "${var.project}-${each.key}-logs" }
}

# ---- VPC Flow Logs ----
resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/aws/vpc/flowlogs/${var.project}"
  retention_in_days = 7
  tags              = { Name = "${var.project}-vpc-flowlogs" }
}

resource "aws_iam_role" "vpc_flow_log" {
  name = "${var.project}-vpc-flow-log-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole"; Effect = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "vpc_flow_log" {
  name   = "${var.project}-vpc-flow-log-policy"
  role   = aws_iam_role.vpc_flow_log.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.vpc_flow.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.vpc_flow_log.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow.arn
  traffic_type    = "ALL"
  vpc_id          = var.vpc_id
  tags            = { Name = "${var.project}-flow-log" }
}

# ---- CloudTrail ----
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project}-cloudtrail-${var.aws_account_id}"
  force_destroy = true
  tags          = { Name = "${var.project}-cloudtrail" }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${var.aws_account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true
  tags                          = { Name = "${var.project}-cloudtrail" }
  depends_on                    = [aws_s3_bucket_policy.cloudtrail]
}

# ---- CloudWatch Alarmes ----

# ALB : taux d'erreurs 5xx > 5%
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Trop d'erreurs 5xx sur l'ALB"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  alarm_actions       = var.sns_alert_arn != "" ? [var.sns_alert_arn] : []
  tags                = { Name = "${var.project}-alb-5xx-alarm" }
}

# RDS : CPU > 80%
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "CPU Aurora trop élevé"
  dimensions          = { DBClusterIdentifier = var.db_cluster_id }
  alarm_actions       = var.sns_alert_arn != "" ? [var.sns_alert_arn] : []
  tags                = { Name = "${var.project}-rds-cpu-alarm" }
}

# RDS : connexions DB > 150
resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.project}-rds-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 150
  alarm_description   = "Trop de connexions ouvertes sur Aurora"
  dimensions          = { DBClusterIdentifier = var.db_cluster_id }
  alarm_actions       = var.sns_alert_arn != "" ? [var.sns_alert_arn] : []
  tags                = { Name = "${var.project}-rds-conn-alarm" }
}

# ---- CloudWatch Dashboard ----
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-monitoring"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "ALB - Requêtes/min"
          period = 60
          stat   = "Sum"
          metrics = [["AWS/ApplicationELB", "RequestCount",
            "LoadBalancer", var.alb_arn_suffix]]
          view = "timeSeries"
        }
        width = 12; height = 6; x = 0; y = 0
      },
      {
        type = "metric"
        properties = {
          title  = "ALB - Erreurs 5xx"
          period = 60
          stat   = "Sum"
          metrics = [["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count",
            "LoadBalancer", var.alb_arn_suffix]]
          view = "timeSeries"
        }
        width = 12; height = 6; x = 12; y = 0
      },
      {
        type = "metric"
        properties = {
          title  = "RDS Aurora - CPU %"
          period = 60
          stat   = "Average"
          metrics = [["AWS/RDS", "CPUUtilization",
            "DBClusterIdentifier", var.db_cluster_id]]
          view = "timeSeries"
        }
        width = 12; height = 6; x = 0; y = 6
      },
      {
        type = "metric"
        properties = {
          title  = "RDS Aurora - Connexions"
          period = 60
          stat   = "Maximum"
          metrics = [["AWS/RDS", "DatabaseConnections",
            "DBClusterIdentifier", var.db_cluster_id]]
          view = "timeSeries"
        }
        width = 12; height = 6; x = 12; y = 6
      }
    ]
  })
}

# ---- SNS Topic (optionnel - pour recevoir les alertes par email) ----
resource "aws_sns_topic" "alerts" {
  count = var.alert_email != "" ? 1 : 0
  name  = "${var.project}-alerts"
  tags  = { Name = "${var.project}-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

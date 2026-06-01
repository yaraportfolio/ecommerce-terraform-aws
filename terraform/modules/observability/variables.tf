variable "project"        {}
variable "environment"    {}
variable "vpc_id"         {}
variable "aws_account_id" {}
variable "cluster_name"   {}
variable "alb_arn_suffix" {}
variable "db_cluster_id"  {}
variable "sns_alert_arn"  { default = "" }
variable "alert_email"    { default = "" }

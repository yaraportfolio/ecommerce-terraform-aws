variable "project"            {}
variable "environment"        {}
variable "aws_region"         {}
variable "vpc_id"             {}
variable "private_subnet_ids" { type = list(string) }

variable "cluster_version"             { default = "1.31" }
variable "metrics_server_version"      { default = null }
variable "lb_controller_chart_version" { default = "1.11.0" }

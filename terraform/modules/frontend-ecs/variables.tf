variable "project"           {}
variable "environment"       {}
variable "vpc_id"            {}
variable "public_subnet_ids" { type = list(string) }
variable "sg_frontend_id"    {}
variable "ecr_frontend_url"  {}
variable "backend_url"       {}
variable "alb_tg_arn"        {}
variable "aws_region"        {}
variable "enabled"           { default = false }

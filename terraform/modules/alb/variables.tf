variable "project"           {}
variable "environment"       {}
variable "vpc_id"            {}
variable "public_subnet_ids" { type = list(string) }
variable "sg_alb_id"         {}
variable "certificate_arn"   { default = "" }

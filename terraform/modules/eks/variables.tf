variable "project"            {}
variable "environment"        {}
variable "aws_region"         {}
variable "vpc_id"             {}
variable "private_subnet_ids" { type = list(string) }
variable "sg_eks_id"          {}
variable "node_instance_type" { default = "t3.medium" }
variable "node_min_size"      { default = 2 }
variable "node_max_size"      { default = 6 }
variable "node_desired"       { default = 3 }

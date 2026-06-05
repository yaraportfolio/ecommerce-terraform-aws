variable "project"           {}
variable "environment"       {}
variable "vpc_id"            {}
variable "public_subnet_ids" { type = list(string) }
variable "sg_frontend_id"    {}
variable "backend_url"       {} # URL de l'ALB interne EKS (proxy /api → microservices)
variable "alb_tg_arn"        {}
variable "enabled"           { default = true }

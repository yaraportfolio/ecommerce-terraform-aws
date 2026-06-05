variable "project"           {}
variable "environment"       {}
variable "vpc_id"            {}
variable "public_subnet_ids" { type = list(string) }
variable "sg_frontend_id"    {}
variable "ecr_frontend_url"  {}
variable "backend_url"       {}
variable "alb_tg_arn"        {} # TG instance de l'ALB public (enregistrement de l'instance EB)
variable "enabled"           { default = false }

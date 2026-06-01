variable "aws_region"               { default = "eu-west-1" }
variable "project"                  { default = "ecommerce" }
variable "environment"              { default = "prod" }
variable "vpc_cidr"                 { default = "10.0.0.0/16" }
variable "db_name"                  { default = "ecommerce_db" }
variable "db_username"              { default = "devops_user" }
variable "db_password"              { sensitive = true }
variable "jwt_secret"               { sensitive = true }
variable "certificate_arn"          { description = "ARN certificat ACM pour HTTPS" }
variable "rds_instance_class"       { default = "db.t3.medium" }
variable "eks_node_instance_type"   { default = "t3.medium" }
variable "eks_node_min"             { default = 2 }
variable "eks_node_max"             { default = 6 }
variable "eks_node_desired"         { default = 3 }
variable "frontend_mode"            { default = "ec2"; description = "ec2 | beanstalk | ecs" }
variable "microservices_image_tag"  { default = "v3.3" }
variable "domain_name"  { default = "" ; description = "ex: ecommerce.votredomaine.com - laisser vide pour utiliser le DNS CloudFront" }
variable "alert_email"  { default = "" ; description = "Email pour les alertes CloudWatch SNS" }

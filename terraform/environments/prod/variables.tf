variable "aws_region"               { default = "eu-west-1" }
variable "project"                  { default = "ecommerce" }
variable "environment"              { default = "prod" }
variable "vpc_cidr"                 { default = "10.0.0.0/16" }
variable "db_name"                  { default = "ecommerce_db" }
variable "db_username"              { default = "devops_user" }
variable "db_password"              { sensitive = true }
variable "jwt_secret"               { sensitive = true }
variable "certificate_arn"          { description = "ARN certificat ACM pour HTTPS" }
variable "rds_instance_class"       { default = "db.t4g.micro" }
variable "eks_cluster_version"      { default = "1.31"; description = "Version Kubernetes du cluster EKS Auto Mode" }
variable "frontend_mode"            { default = "ec2"; description = "ec2 | beanstalk | ecs" }
variable "microservices_image_tag"  { default = "latest" }

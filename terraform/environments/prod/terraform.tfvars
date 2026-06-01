aws_region              = "eu-west-1"
project                 = "ecommerce"
environment             = "prod"
vpc_cidr                = "10.0.0.0/16"
db_name                 = "ecommerce_db"
db_username             = "devops_user"
rds_instance_class      = "db.t3.medium"
eks_node_instance_type  = "t3.medium"
eks_node_min            = 2
eks_node_max            = 6
eks_node_desired        = 3
frontend_mode           = "ec2"
microservices_image_tag = "v3.3"

# ⚠️ Ne pas committer ces valeurs - utiliser TF_VAR_db_password et TF_VAR_jwt_secret
# db_password    = ""
# jwt_secret     = ""
# certificate_arn = "arn:aws:acm:eu-west-1:ACCOUNT:certificate/XXXX"

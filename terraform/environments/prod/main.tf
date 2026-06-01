terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.25" }
    helm       = { source = "hashicorp/helm", version = "~> 2.12" }
  }
  backend "s3" {
    bucket         = "ecommerce-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "ecommerce-terraform-lock"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = var.project, Environment = var.environment, ManagedBy = "Terraform" } }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)
  exec { api_version = "client.authentication.k8s.io/v1beta1"; command = "aws"; args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name] }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec { api_version = "client.authentication.k8s.io/v1beta1"; command = "aws"; args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name] }
  }
}

data "aws_caller_identity" "current" {}

module "vpc"                { source = "../../modules/vpc"; project = var.project; environment = var.environment; aws_region = var.aws_region; vpc_cidr = var.vpc_cidr }
module "sg"                 { source = "../../modules/sg"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id }
module "rds"                { source = "../../modules/rds"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; db_subnet_ids = module.vpc.db_subnet_ids; sg_rds_id = module.sg.sg_rds_id; db_name = var.db_name; db_username = var.db_username; db_password = var.db_password; instance_class = var.rds_instance_class }
module "ecr"                { source = "../../modules/ecr"; project = var.project; services = ["auth-service", "product-service", "order-service", "review-service", "frontend"] }
module "eks"                { source = "../../modules/eks"; project = var.project; environment = var.environment; aws_region = var.aws_region; vpc_id = module.vpc.vpc_id; private_subnet_ids = module.vpc.private_subnet_ids; sg_eks_id = module.sg.sg_eks_id; node_instance_type = var.eks_node_instance_type; node_min_size = var.eks_node_min; node_max_size = var.eks_node_max; node_desired = var.eks_node_desired }
module "alb"                { source = "../../modules/alb"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; public_subnet_ids = module.vpc.public_subnet_ids; sg_alb_id = module.sg.sg_alb_id; certificate_arn = var.certificate_arn }
module "frontend_ec2"       { source = "../../modules/frontend-ec2"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; public_subnet_ids = module.vpc.public_subnet_ids; sg_frontend_id = module.sg.sg_frontend_id; ecr_frontend_url = module.ecr.repository_urls["frontend"]; backend_url = "http://${module.eks.internal_alb_dns}"; alb_tg_arn = module.alb.target_group_arn; enabled = var.frontend_mode == "ec2" }
module "frontend_beanstalk" { source = "../../modules/frontend-beanstalk"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; public_subnet_ids = module.vpc.public_subnet_ids; sg_frontend_id = module.sg.sg_frontend_id; ecr_frontend_url = module.ecr.repository_urls["frontend"]; backend_url = "http://${module.eks.internal_alb_dns}"; enabled = var.frontend_mode == "beanstalk" }
module "frontend_ecs"       { source = "../../modules/frontend-ecs"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; public_subnet_ids = module.vpc.public_subnet_ids; sg_frontend_id = module.sg.sg_frontend_id; ecr_frontend_url = module.ecr.repository_urls["frontend"]; backend_url = "http://${module.eks.internal_alb_dns}"; alb_tg_arn = module.alb.target_group_arn; aws_region = var.aws_region; enabled = var.frontend_mode == "ecs" }

resource "helm_release" "microservices" {
  name             = "ecommerce-microservices"
  chart            = "${path.root}/../../../ecommerce-k8s-helm"
  namespace        = "ecommerce"
  create_namespace = true
  depends_on       = [module.eks]

  set { name = "image.registryType"; value = "ecr" }
  set { name = "image.ecr.registry"; value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com" }
  set { name = "image.ecr.owner"; value = var.project }
  set { name = "services.authService.image.tag"; value = var.microservices_image_tag }
  set { name = "services.productService.image.tag"; value = var.microservices_image_tag }
  set { name = "services.orderService.image.tag"; value = var.microservices_image_tag }
  set { name = "services.reviewService.image.tag"; value = var.microservices_image_tag }
  set { name = "database.host"; value = module.rds.endpoint }
  set { name = "database.name"; value = var.db_name }
  set { name = "database.user"; value = var.db_username }
  set_sensitive { name = "database.password"; value = var.db_password }
  set_sensitive { name = "jwt.secret"; value = var.jwt_secret }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"  # Requis pour ACM + CloudFront
  default_tags { tags = { Project = var.project, Environment = var.environment, ManagedBy = "Terraform" } }
}

module "cloudfront" {
  source      = "../../modules/cloudfront"
  providers   = { aws = aws, aws.us_east_1 = aws.us_east_1 }
  project     = var.project
  environment = var.environment
  alb_dns     = module.alb.alb_dns
  domain_name = var.domain_name
}

module "observability" {
  source          = "../../modules/observability"
  project         = var.project
  environment     = var.environment
  vpc_id          = module.vpc.vpc_id
  aws_account_id  = data.aws_caller_identity.current.account_id
  cluster_name    = module.eks.cluster_name
  alb_arn_suffix  = module.alb.alb_arn_suffix
  db_cluster_id   = module.rds.instance_id
  alert_email     = var.alert_email
}

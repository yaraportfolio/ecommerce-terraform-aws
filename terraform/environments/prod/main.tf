terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.25" }
    helm       = { source = "hashicorp/helm", version = "~> 2.12" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
  }
  # State local (portfolio solo) : pas de backend distant S3/DynamoDB.
  # ⚠️ terraform.tfstate reste sur la machine (à sauvegarder) et contient des
  #    secrets en clair → ne JAMAIS le committer (cf. .gitignore).
  # Pour passer en équipe/CI plus tard : décommenter un backend "s3" ici.
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

module "vpc"                { source = "../../modules/vpc"; project = var.project; environment = var.environment; aws_region = var.aws_region; vpc_cidr = var.vpc_cidr }
module "sg"                 { source = "../../modules/sg"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id }
module "rds"                { source = "../../modules/rds"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; db_subnet_ids = module.vpc.db_subnet_ids; sg_rds_id = module.sg.sg_rds_id; db_name = var.db_name; db_username = var.db_username; db_password = var.db_password; instance_class = var.rds_instance_class }
module "ecr"                { source = "../../modules/ecr"; project = var.project; services = ["frontend"] }
module "eks"                { source = "../../modules/eks"; project = var.project; environment = var.environment; aws_region = var.aws_region; vpc_id = module.vpc.vpc_id; private_subnet_ids = module.vpc.private_subnet_ids; cluster_version = var.eks_cluster_version }

# RDS :3306 ← nœuds EKS Auto Mode (le SG des nœuds = cluster SG, créé par Auto Mode).
resource "aws_security_group_rule" "rds_from_eks" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = module.sg.sg_rds_id
  source_security_group_id = module.eks.cluster_security_group_id
  description              = "EKS Auto Mode nodes vers RDS MySQL"
}

# Secret JWT partagé par les 4 microservices.
resource "aws_secretsmanager_secret" "jwt" {
  name        = "${var.project}/jwt/secret"
  description = "JWT secret partage par les microservices"
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id     = aws_secretsmanager_secret.jwt.id
  secret_string = jsonencode({ JWT_SECRET = var.jwt_secret })
}

# IRSA : les pods (ServiceAccount ecommerce/ecommerce-sa) lisent les secrets depuis
# AWS Secrets Manager via le Secrets Store CSI Driver (ASCP). cf. ARCHITECTURE.md $12.
data "aws_iam_policy_document" "eks_secrets_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:ecommerce:ecommerce-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_secrets" {
  name               = "${var.project}-eks-secrets-role"
  assume_role_policy = data.aws_iam_policy_document.eks_secrets_assume.json
}

resource "aws_iam_role_policy" "eks_secrets" {
  name = "${var.project}-eks-secrets-read"
  role = aws_iam_role.eks_secrets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [module.rds.secret_arn, aws_secretsmanager_secret.jwt.arn]
    }]
  })
}
module "alb"                { source = "../../modules/alb"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; public_subnet_ids = module.vpc.public_subnet_ids; sg_alb_id = module.sg.sg_alb_id; certificate_arn = var.certificate_arn }
# DNS de l'ALB interne créé par le LBC, lu depuis l'Ingress du chart Helm.
# 1er apply : vide (l'ALB se provisionne en asynchrone) → 2e apply : peuplé.
data "kubernetes_ingress_v1" "api" {
  metadata {
    name      = "api-ingress"
    namespace = "ecommerce"
  }
  depends_on = [helm_release.microservices]
}

locals {
  internal_alb_dns = try(data.kubernetes_ingress_v1.api.status[0].load_balancer[0].ingress[0].hostname, "")
  backend_url      = local.internal_alb_dns != "" ? "http://${local.internal_alb_dns}" : ""
}

module "frontend_ec2"       { source = "../../modules/frontend-ec2"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; public_subnet_ids = module.vpc.public_subnet_ids; sg_frontend_id = module.sg.sg_frontend_id; backend_url = local.backend_url; alb_tg_arn = module.alb.target_group_arn; enabled = var.frontend_mode == "ec2" }
module "frontend_beanstalk" { source = "../../modules/frontend-beanstalk"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; public_subnet_ids = module.vpc.public_subnet_ids; sg_frontend_id = module.sg.sg_frontend_id; ecr_frontend_url = module.ecr.repository_urls["frontend"]; backend_url = local.backend_url; alb_tg_arn = module.alb.target_group_arn; enabled = var.frontend_mode == "beanstalk" }
module "frontend_ecs"       { source = "../../modules/frontend-ecs"; project = var.project; environment = var.environment; vpc_id = module.vpc.vpc_id; public_subnet_ids = module.vpc.public_subnet_ids; sg_frontend_id = module.sg.sg_frontend_id; ecr_frontend_url = module.ecr.repository_urls["frontend"]; backend_url = local.backend_url; https_listener_arn = module.alb.https_listener_arn; aws_region = var.aws_region; enabled = var.frontend_mode == "ecs" }

resource "helm_release" "microservices" {
  name             = "ecommerce-microservices"
  chart            = "${path.root}/../../../ecommerce-k8s-helm"
  namespace        = "ecommerce"
  create_namespace = true
  depends_on       = [module.eks, aws_iam_role_policy.eks_secrets, aws_secretsmanager_secret_version.jwt]

  # Microservices use GHCR (public GitHub Container Registry)
  set { name = "image.registryType"; value = "ghcr" }
  set { name = "image.ghcr.registry"; value = "ghcr.io" }
  set { name = "image.ghcr.owner"; value = "yaraportfolio" }
  set { name = "services.authService.image.tag"; value = var.microservices_image_tag }
  set { name = "services.productService.image.tag"; value = var.microservices_image_tag }
  set { name = "services.orderService.image.tag"; value = var.microservices_image_tag }
  set { name = "services.reviewService.image.tag"; value = var.microservices_image_tag }

  # DB host/name → ConfigMap (DB_HOST/DB_NAME)
  set { name = "database.host"; value = module.rds.endpoint }
  set { name = "database.name"; value = var.db_name }

  # Secrets (DB_USER/DB_PASSWORD/JWT_SECRET) fournis par AWS Secrets Manager
  # via le Secrets Store CSI Driver + IRSA (ecommerce-eks-secrets-role).
  set { name = "awsSecretsManager.enabled";    value = "true" }
  set { name = "awsSecretsManager.region";     value = var.aws_region }
  set { name = "awsSecretsManager.iamRoleArn"; value = aws_iam_role.eks_secrets.arn }
  set { name = "awsSecretsManager.secrets.dbCredentials.secretName"; value = "${var.project}/db/credentials" }
  set { name = "awsSecretsManager.secrets.jwtSecret.secretName";     value = "${var.project}/jwt/secret" }
}

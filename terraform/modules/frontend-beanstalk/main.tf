# =============================================================================
# Frontend Option B - Elastic Beanstalk (Single instance, image Docker ECR)
# cf. ARCHITECTURE.md $6 et GUIDE-CONSOLE-AWS.md $10
# =============================================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Résout dynamiquement le dernier solution stack Docker (évite un nom de version codé en dur)
data "aws_elastic_beanstalk_solution_stack" "docker" {
  most_recent = true
  name_regex  = "^64bit Amazon Linux 2023 (.*) running Docker$"
}

# Rôle d'instance EC2 de Beanstalk : SSM + WebTier + lecture ECR (pull image frontend)
resource "aws_iam_role" "beanstalk_ec2" {
  count = var.enabled ? 1 : 0
  name  = "${var.project}-beanstalk-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole"; Effect = "Allow"; Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "beanstalk_ec2" {
  for_each = var.enabled ? toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]) : toset([])
  role       = aws_iam_role.beanstalk_ec2[0].name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "beanstalk_ec2" {
  count = var.enabled ? 1 : 0
  name  = "${var.project}-beanstalk-ec2-role"
  role  = aws_iam_role.beanstalk_ec2[0].name
}

# Rôle de service Beanstalk (gère l'infra : health, managed updates)
resource "aws_iam_role" "beanstalk_service" {
  count = var.enabled ? 1 : 0
  name  = "${var.project}-beanstalk-service-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole"; Effect = "Allow"; Principal = { Service = "elasticbeanstalk.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "beanstalk_service" {
  for_each = var.enabled ? toset([
    "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth",
    "arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy",
  ]) : toset([])
  role       = aws_iam_role.beanstalk_service[0].name
  policy_arn = each.value
}

# ---- Source bundle : Dockerrun.aws.json (image ECR) sur S3 ----
# Le bucket commence par "elasticbeanstalk-" pour être couvert par les policies EB
# (WebTier sur l'instance + service-linked role) qui autorisent s3:Get sur ce préfixe.
locals {
  dockerrun = jsonencode({
    AWSEBDockerrunVersion = "1"
    Image                 = { Name = "${var.ecr_frontend_url}:latest", Update = "true" }
    Ports                 = [{ ContainerPort = "80" }]
  })
}

resource "aws_s3_bucket" "eb" {
  count         = var.enabled ? 1 : 0
  bucket        = "elasticbeanstalk-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}-${var.project}"
  force_destroy = true
  tags          = { Name = "${var.project}-eb-deployments" }
}

resource "aws_s3_object" "dockerrun" {
  count   = var.enabled ? 1 : 0
  bucket  = aws_s3_bucket.eb[0].id
  key     = "frontend/Dockerrun.aws.json"
  content = local.dockerrun
  etag    = md5(local.dockerrun)
}

resource "aws_elastic_beanstalk_application" "frontend" {
  count       = var.enabled ? 1 : 0
  name        = "${var.project}-frontend"
  description = "Frontend e-commerce React + NGINX"
}

# Le hash du Dockerrun dans le nom → toute nouvelle image crée une nouvelle version
# et déclenche un redéploiement de l'environnement.
resource "aws_elastic_beanstalk_application_version" "frontend" {
  count       = var.enabled ? 1 : 0
  name        = "${var.project}-frontend-${substr(md5(local.dockerrun), 0, 8)}"
  application = aws_elastic_beanstalk_application.frontend[0].name
  description = "Frontend ECR ${var.ecr_frontend_url}:latest"
  bucket      = aws_s3_bucket.eb[0].id
  key         = aws_s3_object.dockerrun[0].key
}

resource "aws_elastic_beanstalk_environment" "frontend" {
  count               = var.enabled ? 1 : 0
  name                = "${var.project}-frontend-prod"
  application         = aws_elastic_beanstalk_application.frontend[0].name
  version_label       = aws_elastic_beanstalk_application_version.frontend[0].name
  solution_stack_name = data.aws_elastic_beanstalk_solution_stack.docker.name

  # Single instance (cf. ARCHITECTURE.md $6) - l'instance est ensuite enregistrée
  # dans le Target Group de l'ALB public partagé, comme l'Option A.
  setting { namespace = "aws:elasticbeanstalk:environment";              name = "EnvironmentType";          value = "SingleInstance" }
  setting { namespace = "aws:elasticbeanstalk:environment";              name = "ServiceRole";              value = aws_iam_role.beanstalk_service[0].name }
  setting { namespace = "aws:autoscaling:launchconfiguration";           name = "InstanceType";             value = "t3.micro" }
  setting { namespace = "aws:autoscaling:launchconfiguration";           name = "SecurityGroups";           value = var.sg_frontend_id }
  setting { namespace = "aws:autoscaling:launchconfiguration";           name = "IamInstanceProfile";       value = aws_iam_instance_profile.beanstalk_ec2[0].name }
  setting { namespace = "aws:ec2:vpc";                                   name = "VPCId";                    value = var.vpc_id }
  setting { namespace = "aws:ec2:vpc";                                   name = "Subnets";                  value = join(",", var.public_subnet_ids) }
  setting { namespace = "aws:ec2:vpc";                                   name = "AssociatePublicIpAddress"; value = "true" }
  setting { namespace = "aws:elasticbeanstalk:application:environment";  name = "BACKEND_URL";              value = var.backend_url }
  setting { namespace = "aws:elasticbeanstalk:application:environment";  name = "BACKEND_HOST";             value = "ecommerce.mondomaine.app" }
}

# Enregistre l'instance EB (single instance) dans le TG de l'ALB public partagé.
# L'environnement étant "Ready" quand l'instance tourne, le data source la trouve dès le 1er apply.
data "aws_instances" "beanstalk" {
  count                = var.enabled ? 1 : 0
  instance_tags        = { "elasticbeanstalk:environment-name" = aws_elastic_beanstalk_environment.frontend[0].name }
  instance_state_names = ["running"]
}

resource "aws_lb_target_group_attachment" "beanstalk" {
  count            = var.enabled ? 1 : 0
  target_group_arn = var.alb_tg_arn
  target_id        = data.aws_instances.beanstalk[0].ids[0]
  port             = 80
}

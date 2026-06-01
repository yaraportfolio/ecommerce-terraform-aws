resource "aws_elastic_beanstalk_application" "frontend" {
  count       = var.enabled ? 1 : 0
  name        = "${var.project}-frontend"
  description = "Frontend e-commerce React + NGINX"
}

resource "aws_elastic_beanstalk_environment" "frontend" {
  count               = var.enabled ? 1 : 0
  name                = "${var.project}-frontend-prod"
  application         = aws_elastic_beanstalk_application.frontend[0].name
  solution_stack_name = "64bit Amazon Linux 2 v3.8.0 running Docker"

  setting { namespace = "aws:autoscaling:asg";                      name = "MinSize";        value = "2" }
  setting { namespace = "aws:autoscaling:asg";                      name = "MaxSize";        value = "6" }
  setting { namespace = "aws:autoscaling:launchconfiguration";      name = "InstanceType";   value = "t3.medium" }
  setting { namespace = "aws:autoscaling:launchconfiguration";      name = "SecurityGroups"; value = var.sg_frontend_id }
  setting { namespace = "aws:ec2:vpc";                              name = "VPCId";          value = var.vpc_id }
  setting { namespace = "aws:ec2:vpc";                              name = "Subnets";        value = join(",", var.public_subnet_ids) }
  setting { namespace = "aws:elasticbeanstalk:application:environment"; name = "BACKEND_URL";   value = var.backend_url }
  setting { namespace = "aws:elasticbeanstalk:application:environment"; name = "BACKEND_HOST";  value = "api.ecommerce.local" }
}

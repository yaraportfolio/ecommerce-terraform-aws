data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name"; values = ["amzn2-ami-hvm-*-x86_64-gp2"] }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    amazon-linux-extras install docker -y
    service docker start
    usermod -a -G docker ec2-user
    aws ecr get-login-password --region ${data.aws_region.current.name} | \
      docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com
    docker run -d --name frontend -p 80:80 \
      -e BACKEND_URL=${var.backend_url} \
      -e BACKEND_HOST=api.ecommerce.local \
      --restart always ${var.ecr_frontend_url}:latest
  USERDATA
  )
}

resource "aws_iam_instance_profile" "frontend" {
  count = var.enabled ? 1 : 0
  name  = "${var.project}-frontend-ec2-profile"
  role  = aws_iam_role.frontend[0].name
}

resource "aws_iam_role" "frontend" {
  count = var.enabled ? 1 : 0
  name  = "${var.project}-frontend-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole"; Effect = "Allow"; Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  count      = var.enabled ? 1 : 0
  role       = aws_iam_role.frontend[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_launch_template" "frontend" {
  count                  = var.enabled ? 1 : 0
  name                   = "${var.project}-frontend-lt"
  image_id               = data.aws_ami.amazon_linux.id
  instance_type          = "t3.medium"
  vpc_security_group_ids = [var.sg_frontend_id]
  user_data              = local.user_data
  iam_instance_profile   { name = aws_iam_instance_profile.frontend[0].name }
  tag_specifications { resource_type = "instance"; tags = { Name = "${var.project}-frontend" } }
}

resource "aws_autoscaling_group" "frontend" {
  count                = var.enabled ? 1 : 0
  name                 = "${var.project}-frontend-asg"
  min_size             = 2
  max_size             = 6
  desired_capacity     = 2
  vpc_zone_identifier  = var.public_subnet_ids
  target_group_arns    = [var.alb_tg_arn]
  health_check_type    = "ELB"
  health_check_grace_period = 120
  launch_template { id = aws_launch_template.frontend[0].id; version = "$Latest" }
  tag { key = "Name"; value = "${var.project}-frontend"; propagate_at_launch = true }
}

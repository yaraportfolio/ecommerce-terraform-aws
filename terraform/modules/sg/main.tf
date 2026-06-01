resource "aws_security_group" "alb" {
  name        = "${var.project}-sg-alb"
  description = "ALB public - HTTP/HTTPS depuis internet"
  vpc_id      = var.vpc_id
  ingress { from_port = 80;  to_port = 80;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0;   to_port = 0;   protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "${var.project}-sg-alb" }
}

resource "aws_security_group" "frontend" {
  name        = "${var.project}-sg-frontend"
  description = "Frontend - trafic depuis ALB uniquement"
  vpc_id      = var.vpc_id
  ingress { from_port = 80; to_port = 80; protocol = "tcp"; security_groups = [aws_security_group.alb.id] }
  egress  { from_port = 0;  to_port = 0;  protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "${var.project}-sg-frontend" }
}

resource "aws_security_group" "eks" {
  name        = "${var.project}-sg-eks"
  description = "EKS nodes - microservices"
  vpc_id      = var.vpc_id
  ingress { from_port = 3001; to_port = 3004; protocol = "tcp"; security_groups = [aws_security_group.frontend.id] }
  ingress { from_port = 0;    to_port = 0;    protocol = "-1";  self = true }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "${var.project}-sg-eks" }
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-sg-rds"
  description = "RDS Aurora - MySQL depuis EKS uniquement"
  vpc_id      = var.vpc_id
  ingress { from_port = 3306; to_port = 3306; protocol = "tcp"; security_groups = [aws_security_group.eks.id] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "${var.project}-sg-rds" }
}

# Security Groups créés manuellement (cf. GUIDE-CONSOLE-AWS.md $3).
# Le SG des nœuds EKS est créé automatiquement par EKS Auto Mode (cluster security group)
# et n'est donc PAS défini ici - la règle RDS ← nœuds EKS est ajoutée côté env (prod/main.tf)
# une fois le cluster créé, car elle référence le cluster_security_group_id d'Auto Mode.

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

resource "aws_security_group" "rds" {
  name        = "${var.project}-sg-rds"
  description = "RDS MySQL - acces depuis les noeuds EKS uniquement"
  vpc_id      = var.vpc_id
  # Règle :3306 ← nœuds EKS ajoutée dans prod/main.tf (référence le cluster SG Auto Mode)
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = { Name = "${var.project}-sg-rds" }
}

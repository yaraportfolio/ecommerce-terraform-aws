resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = var.db_subnet_ids
  tags       = { Name = "${var.project}-db-subnet-group" }
}

# RDS MySQL 8.4 - db.t4g.micro (ARM Graviton), Single-AZ (choix Free Tier / portfolio).
# cf. ARCHITECTURE.md $10 et GUIDE-CONSOLE-AWS.md $4.
resource "aws_db_instance" "mysql" {
  identifier              = "${var.project}-mysql"
  engine                  = "mysql"
  engine_version          = var.engine_version
  instance_class          = var.instance_class
  allocated_storage       = 20
  storage_type            = "gp2"
  username                = var.db_username
  password                = var.db_password
  db_name                 = var.db_name
  port                    = 3306
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [var.sg_rds_id]
  backup_retention_period = var.backup_retention_period
  storage_encrypted       = true
  multi_az                = false
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  tags = { Name = "${var.project}-mysql" }
}

# Secret DB - clés DB_USER / DB_PASSWORD (consommées par les microservices).
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project}/db/credentials"
  description = "Credentials RDS MySQL ecommerce"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    DB_USER     = var.db_username
    DB_PASSWORD = var.db_password
  })
}

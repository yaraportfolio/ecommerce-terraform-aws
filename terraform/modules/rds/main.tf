resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = var.db_subnet_ids
  tags       = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_db_instance" "mysql" {
  identifier            = "${var.project}-mysql"
  engine                = "mysql"
  engine_version        = "8.0.35"
  instance_class        = var.instance_class
  allocated_storage     = 20
  username              = var.db_username
  password              = var.db_password
  db_name               = var.db_name
  db_subnet_group_name  = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.sg_rds_id]
  backup_retention_period = 7
  storage_encrypted     = true
  multi_az              = true
  skip_final_snapshot   = false
  final_db_snapshot_identifier = "${var.project}-final-snapshot"
  publicly_accessible   = false
  tags = { Name = "${var.project}-mysql" }
}

# Stocker les credentials dans Secrets Manager
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project}/db/credentials"
  description = "RDS MySQL credentials"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = aws_db_instance.mysql.address
    port     = 3306
    dbname   = var.db_name
  })
}

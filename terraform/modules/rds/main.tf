resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = var.db_subnet_ids
  tags       = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier      = "${var.project}-aurora-cluster"
  engine                  = "aurora-mysql"
  engine_version          = "8.0.mysql_aurora.3.05.2"
  master_username         = var.db_username
  master_password         = var.db_password
  database_name           = var.db_name
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [var.sg_rds_id]
  backup_retention_period = 7
  storage_encrypted       = true
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.project}-final-snapshot"
  tags = { Name = "${var.project}-aurora-cluster" }
}

resource "aws_rds_cluster_instance" "primary" {
  identifier         = "${var.project}-aurora-primary"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  publicly_accessible = false
  tags = { Name = "${var.project}-aurora-primary" }
}

# Stocker les credentials dans Secrets Manager
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project}/db/credentials"
  description = "RDS Aurora credentials"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = aws_rds_cluster.aurora.endpoint
    port     = 3306
    dbname   = var.db_name
  })
}

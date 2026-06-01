output "endpoint"       { value = aws_db_instance.mysql.address }
output "secret_arn"     { value = aws_secretsmanager_secret.db.arn }
output "instance_id"    { value = aws_db_instance.mysql.identifier }

output "cluster_endpoint"       { value = aws_rds_cluster.aurora.endpoint }
output "reader_endpoint"        { value = aws_rds_cluster.aurora.reader_endpoint }
output "secret_arn"             { value = aws_secretsmanager_secret.db.arn }
output "cluster_id" { value = aws_rds_cluster.aurora.cluster_identifier }

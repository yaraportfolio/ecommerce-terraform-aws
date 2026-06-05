output "instance_id" { value = var.enabled ? aws_instance.frontend[0].id : "" }

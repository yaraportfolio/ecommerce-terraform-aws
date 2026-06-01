output "asg_name" { value = var.enabled ? aws_autoscaling_group.frontend[0].name : "" }

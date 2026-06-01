output "endpoint" { value = var.enabled ? aws_elastic_beanstalk_environment.frontend[0].endpoint_url : "" }

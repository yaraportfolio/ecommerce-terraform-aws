output "vpc_id"              { value = module.vpc.vpc_id }
output "alb_dns"             { value = module.alb.alb_dns }
output "rds_endpoint"        { value = module.rds.endpoint }
output "eks_cluster_name"    { value = module.eks.cluster_name }
output "ecr_urls"            { value = module.ecr.repository_urls }
output "frontend_mode"       { value = var.frontend_mode }

output "cluster_name"     { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "cluster_ca"       { value = aws_eks_cluster.main.certificate_authority[0].data }

# SG primaire du cluster (porté par les nœuds Auto Mode) - source pour la règle RDS:3306
output "cluster_security_group_id" { value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id }

output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.eks.arn }
output "oidc_provider_url" { value = local.oidc_issuer } # issuer sans "https://" (conditions IRSA)
# Note : le DNS de l'ALB interne est lu côté env (prod) via la data source
# kubernetes_ingress_v1 "api-ingress", pas exposé ici (créé en async par le LBC).

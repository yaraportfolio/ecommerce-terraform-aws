# =============================================================================
# EKS Auto Mode (cf. ARCHITECTURE.md $8 et GUIDE-CONSOLE-AWS.md $7)
# AWS gère les nœuds automatiquement (pas de Node Group, pas de Cluster Autoscaler).
# Le control plane, le compute, le block storage et le réseau sont gérés par Auto Mode.
# L'exposition des microservices se fait via l'AWS Load Balancer Controller (Helm, IRSA),
# qui crée un ALB interne à partir de l'Ingress du chart Helm.
# =============================================================================

# ---- Rôle IAM du cluster (Auto Mode) ----
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals { type = "Service"; identifiers = ["eks.amazonaws.com"] }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
  ])
  role       = aws_iam_role.eks_cluster.name
  policy_arn = each.value
}

# ---- Rôle IAM des nœuds (Auto Mode) ----
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["ec2.amazonaws.com"] }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.project}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

# ---- Cluster EKS Auto Mode ----
resource "aws_eks_cluster" "main" {
  name     = "${var.project}-cluster"
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  access_config { authentication_mode = "API" }
  bootstrap_self_managed_addons = false

  compute_config {
    enabled       = true
    node_pools    = ["general-purpose", "system"]
    node_role_arn = aws_iam_role.eks_node.arn
  }

  # Le réseau est géré par Auto Mode. L'équilibrage de charge passe par le
  # AWS Load Balancer Controller standalone (Helm ci-dessous), pas par le LB intégré.
  kubernetes_network_config {
    elastic_load_balancing { enabled = false }
  }

  storage_config {
    block_storage { enabled = true }
  }

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
  tags = { Name = "${var.project}-cluster" }
}

# ---- Add-on Metrics Server (requis pour le HPA) ----
resource "aws_eks_addon" "metrics_server" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "metrics-server"
  addon_version = var.metrics_server_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# ---- OIDC provider (IRSA) ----
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# ---- AWS Load Balancer Controller (IRSA + Helm) ----
resource "aws_iam_policy" "lb_controller" {
  name        = "${var.project}-lb-controller"
  description = "IAM policy pour le AWS Load Balancer Controller"
  # Télécharger la policy officielle :
  # curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
  # mv iam_policy.json modules/eks/lb_controller_policy.json
  policy = file("${path.module}/lb_controller_policy.json")
}

locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

resource "aws_iam_role" "lb_controller" {
  name = "${var.project}-lb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = var.lb_controller_chart_version

  set { name = "clusterName";           value = aws_eks_cluster.main.name }
  set { name = "serviceAccount.create"; value = "true" }
  set { name = "serviceAccount.name";   value = "aws-load-balancer-controller" }
  set { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
        value = aws_iam_role.lb_controller.arn }
  set { name = "region"; value = var.aws_region }
  set { name = "vpcId";  value = var.vpc_id }

  depends_on = [aws_eks_cluster.main, aws_iam_role_policy_attachment.lb_controller]
}

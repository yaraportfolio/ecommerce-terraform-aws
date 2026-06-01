data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["eks.amazonaws.com"] }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  for_each   = toset(["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"])
  role       = aws_iam_role.eks_cluster.name
  policy_arn = each.value
}

resource "aws_eks_cluster" "main" {
  name     = "${var.project}-cluster"
  version  = "1.29"
  role_arn = aws_iam_role.eks_cluster.arn
  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [var.sg_eks_id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }
  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
  tags = { Name = "${var.project}-cluster" }
}

# Node Group IAM
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["ec2.amazonaws.com"] }
  }
}

resource "aws_iam_role" "eks_nodes" {
  name               = "${var.project}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  ])
  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.node_instance_type]
  scaling_config  { min_size = var.node_min_size; max_size = var.node_max_size; desired_size = var.node_desired }
  update_config   { max_unavailable = 1 }
  depends_on = [aws_iam_role_policy_attachment.eks_nodes]
  tags = { Name = "${var.project}-node" }
}

# ---- Cluster Autoscaler ----
# Tag requis sur le Node Group pour que le Cluster Autoscaler puisse le découvrir
resource "aws_autoscaling_group_tag" "cluster_autoscaler" {
  for_each = {
    "k8s.io/cluster-autoscaler/enabled"                     = "true"
    "k8s.io/cluster-autoscaler/${var.project}-cluster"      = "owned"
  }
  autoscaling_group_name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name
  tag { key = each.key; value = each.value; propagate_at_launch = false }
}

# IAM policy pour le Cluster Autoscaler
resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${var.project}-cluster-autoscaler"
  description = "Permet au Cluster Autoscaler de gérer les ASG"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# Déploiement du Cluster Autoscaler via Helm
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.37.0"

  set { name = "autoDiscovery.clusterName"; value = aws_eks_cluster.main.name }
  set { name = "awsRegion";                 value = var.aws_region }
  set { name = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
        value = aws_iam_role.eks_nodes.arn }

  depends_on = [aws_eks_node_group.main]
}

# ---- AWS Load Balancer Controller ----
# Créé le policy IAM et le service account, puis déploie via Helm
resource "aws_iam_policy" "lb_controller" {
  name        = "${var.project}-lb-controller"
  description = "IAM policy pour le AWS Load Balancer Controller"
  policy      = file("${path.module}/lb_controller_policy.json")
}

# Note : le fichier lb_controller_policy.json doit être téléchargé :
# curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json
# mv iam_policy.json modules/eks/lb_controller_policy.json

resource "aws_iam_role" "lb_controller" {
  name = "${var.project}-lb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = aws_eks_cluster.main.identity[0].oidc[0].issuer }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
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
  version    = "1.7.2"

  set { name = "clusterName";                         value = aws_eks_cluster.main.name }
  set { name = "serviceAccount.create";               value = "true" }
  set { name = "serviceAccount.name";                 value = "aws-load-balancer-controller" }
  set { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
        value = aws_iam_role.lb_controller.arn }
  set { name = "region";                              value = var.aws_region }
  set { name = "vpcId";                               value = var.vpc_id }

  depends_on = [aws_eks_node_group.main, aws_iam_role_policy_attachment.lb_controller]
}

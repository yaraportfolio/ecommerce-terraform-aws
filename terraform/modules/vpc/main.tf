resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# Découpage réel (cf. ARCHITECTURE.md / GUIDE-CONSOLE-AWS.md) : 3 AZ, subnets en /20.
locals {
  azs = { a = "${var.aws_region}a", b = "${var.aws_region}b", c = "${var.aws_region}c" }

  public_cidrs  = { a = "10.0.0.0/20",   b = "10.0.16.0/20",  c = "10.0.32.0/20" }
  db_cidrs      = { a = "10.0.48.0/20",  b = "10.0.64.0/20",  c = "10.0.80.0/20" }
  private_cidrs = { a = "10.0.128.0/20", b = "10.0.144.0/20", c = "10.0.160.0/20" }

  cluster_tag = "kubernetes.io/cluster/${var.project}-cluster"

  # Une NAT GW en AZ a et b (cf. architecture). Le subnet 'c' route via la NAT de l'AZ a.
  private_nat_az = { a = "a", b = "b", c = "a" }
}

# Subnets publics (3 AZ) - ALB public, NAT, frontend
resource "aws_subnet" "public" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[each.key]
  availability_zone       = each.value
  map_public_ip_on_launch = true
  tags = {
    Name                      = "${var.project}-subnet-public-${each.key}"
    "kubernetes.io/role/elb"  = "1"
    (local.cluster_tag)       = "shared"
  }
}

# Subnets privés (3 AZ) - nœuds EKS Auto Mode, pods, ALB interne
resource "aws_subnet" "private" {
  for_each          = local.azs
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[each.key]
  availability_zone = each.value
  tags = {
    Name                              = "${var.project}-subnet-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
    (local.cluster_tag)               = "shared"
  }
}

# Subnets base de données (3 AZ) - isolés, RDS MySQL
resource "aws_subnet" "db" {
  for_each          = local.azs
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.db_cidrs[each.key]
  availability_zone = each.value
  tags              = { Name = "${var.project}-db-${each.key}" }
}

# EIPs + NAT GWs (une par AZ a/b)
resource "aws_eip" "nat" {
  for_each = { a = true, b = true }
  domain   = "vpc"
  tags     = { Name = "${var.project}-eip-${each.key}" }
}

resource "aws_nat_gateway" "main" {
  for_each      = { a = aws_subnet.public["a"].id, b = aws_subnet.public["b"].id }
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = each.value
  tags          = { Name = "${var.project}-nat-${each.key}" }
  depends_on    = [aws_internet_gateway.main]
}

# Route table publique → IGW (une pour les 3 subnets publics)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; gateway_id = aws_internet_gateway.main.id }
  tags = { Name = "${var.project}-rt-pub" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Route tables privées (une par NAT, AZ a/b)
resource "aws_route_table" "private" {
  for_each = { a = aws_nat_gateway.main["a"].id, b = aws_nat_gateway.main["b"].id }
  vpc_id   = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; nat_gateway_id = each.value }
  tags = { Name = "${var.project}-rt-priv-${each.key}" }
}

# Privés a/b/c → rt de leur NAT (c partage la NAT de l'AZ a)
resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[local.private_nat_az[each.key]].id
}

# DB a/b/c → mêmes route tables privées
resource "aws_route_table_association" "db" {
  for_each       = aws_subnet.db
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[local.private_nat_az[each.key]].id
}

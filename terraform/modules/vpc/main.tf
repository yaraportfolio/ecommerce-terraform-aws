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

# Subnets publics (3 AZ)
resource "aws_subnet" "public" {
  for_each                = { a = "${var.aws_region}a", b = "${var.aws_region}b", c = "${var.aws_region}c" }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${index(["a","b","c"], each.key) + 1}.0/24"
  availability_zone       = each.value
  map_public_ip_on_launch = true
  tags = {
    Name                   = "${var.project}-pub-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

# Subnets privés (EKS)
resource "aws_subnet" "private" {
  for_each          = { a = "${var.aws_region}a", b = "${var.aws_region}b" }
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${index(["a","b"], each.key) + 10}.0/24"
  availability_zone = each.value
  tags = {
    Name = "${var.project}-priv-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Subnets DB
resource "aws_subnet" "db" {
  for_each          = { a = "${var.aws_region}a", b = "${var.aws_region}b" }
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${index(["a","b"], each.key) + 20}.0/24"
  availability_zone = each.value
  tags              = { Name = "${var.project}-db-${each.key}" }
}

# EIPs + NAT GWs
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

# Route table publique
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

# Route tables privées (une par AZ)
resource "aws_route_table" "private" {
  for_each = { a = aws_nat_gateway.main["a"].id, b = aws_nat_gateway.main["b"].id }
  vpc_id   = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; nat_gateway_id = each.value }
  tags = { Name = "${var.project}-rt-priv-${each.key}" }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "db" {
  for_each       = aws_subnet.db
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

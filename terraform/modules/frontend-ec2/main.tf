# =============================================================================
# Frontend Option A - EC2 (NGINX natif, instance unique) - cf. ARCHITECTURE.md $6
# Build React fait directement sur la VM (npm run build), SANS Docker, SANS ASG.
# Accès via AWS Systems Manager Session Manager uniquement (pas de clé SSH).
# =============================================================================

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name";                values = ["al2023-ami-*-x86_64"] }
  filter { name = "virtualization-type"; values = ["hvm"] }
}

# Rôle IAM : SSM Session Manager uniquement (build natif → pas besoin d'ECR)
resource "aws_iam_role" "frontend" {
  count = var.enabled ? 1 : 0
  name  = "${var.project}-frontend-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole"; Effect = "Allow"; Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.enabled ? 1 : 0
  role       = aws_iam_role.frontend[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "frontend" {
  count = var.enabled ? 1 : 0
  name  = "${var.project}-frontend-ec2-profile"
  role  = aws_iam_role.frontend[0].name
}

locals {
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    ALB_URL="${var.backend_url}"
    dnf update -y
    dnf install -y nginx git nodejs npm
    cd /opt
    git clone https://github.com/yaraportfolio/ecommerce-frontend.git
    cd ecommerce-frontend
    echo "VITE_DEPLOY_PLATFORM=ec2" > .env.production
    npm ci && npm run build
    cp -r dist/* /usr/share/nginx/html/
    cat > /etc/nginx/conf.d/ecommerce.conf << 'NGINXEOF'
    server {
        listen 80;
        root /usr/share/nginx/html;
        index index.html;
        location / { try_files $uri $uri/ /index.html; }
        location /api/ { proxy_pass ALB_PLACEHOLDER/api/; proxy_set_header Host $host; }
    }
    NGINXEOF
    sed -i "s|ALB_PLACEHOLDER|$ALB_URL|g" /etc/nginx/conf.d/ecommerce.conf
    systemctl enable --now nginx
  USERDATA
  )
}

# Instance unique (pas d'Auto Scaling Group) - choix portfolio / Free Tier
resource "aws_instance" "frontend" {
  count                       = var.enabled ? 1 : 0
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [var.sg_frontend_id]
  iam_instance_profile        = aws_iam_instance_profile.frontend[0].name
  associate_public_ip_address = true
  user_data                   = local.user_data
  tags = { Name = "${var.project}-frontend-ec2" }
}

# Enregistrement manuel dans le Target Group de l'ALB public
resource "aws_lb_target_group_attachment" "frontend" {
  count            = var.enabled ? 1 : 0
  target_group_arn = var.alb_tg_arn
  target_id        = aws_instance.frontend[0].id
  port             = 80
}

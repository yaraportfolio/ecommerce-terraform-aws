resource "aws_lb" "public" {
  name               = "${var.project}-alb-pub"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.sg_alb_id]
  subnets            = var.public_subnet_ids
  tags               = { Name = "${var.project}-alb-pub" }
}

resource "aws_lb_target_group" "frontend" {
  name        = "${var.project}-tg-frontend"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"
  health_check { path = "/"; interval = 30; healthy_threshold = 2; unhealthy_threshold = 3 }
  tags = { Name = "${var.project}-tg-frontend" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"
  default_action { type = "redirect"; redirect { port = "443"; protocol = "HTTPS"; status_code = "HTTP_301" } }
}

resource "aws_lb_listener" "https" {
  count             = var.certificate_arn != "" ? 1 : 0
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.frontend.arn }
}

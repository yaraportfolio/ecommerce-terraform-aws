resource "aws_ecs_cluster" "frontend" {
  count = var.enabled ? 1 : 0
  name  = "${var.project}-frontend-cluster"
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE";      weight = 1
  }
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"; weight = 4
  }
}

resource "aws_cloudwatch_log_group" "frontend" {
  count             = var.enabled ? 1 : 0
  name              = "/ecs/${var.project}-frontend"
  retention_in_days = 7
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions    = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["ecs-tasks.amazonaws.com"] }
  }
}

resource "aws_iam_role" "ecs_exec" {
  count              = var.enabled ? 1 : 0
  name               = "${var.project}-ecs-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_exec" {
  count      = var.enabled ? 1 : 0
  role       = aws_iam_role.ecs_exec[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "frontend" {
  count                    = var.enabled ? 1 : 0
  family                   = "${var.project}-frontend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_exec[0].arn

  container_definitions = jsonencode([{
    name      = "frontend"
    image     = "${var.ecr_frontend_url}:latest"
    essential = true
    portMappings = [{ containerPort = 80 }]
    environment = [
      { name = "BACKEND_URL";  value = var.backend_url },
      { name = "BACKEND_HOST"; value = "api.ecommerce.local" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options   = {
        "awslogs-group"         = "/ecs/${var.project}-frontend"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost/ || exit 1"]
      interval    = 30; timeout = 5; retries = 3
    }
  }])
}

resource "aws_ecs_service" "frontend" {
  count           = var.enabled ? 1 : 0
  name            = "${var.project}-frontend-svc"
  cluster         = aws_ecs_cluster.frontend[0].id
  task_definition = aws_ecs_task_definition.frontend[0].arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [var.sg_frontend_id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = var.alb_tg_arn
    container_name   = "frontend"
    container_port   = 80
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
}

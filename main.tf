data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_vpcs" "default" {
  filter {
    name   = "is-default"
    values = ["true"]
  }
  lifecycle {
    postcondition {
      condition     = length(self.ids) == 1
      error_message = "No default VPC found in this region. Ask your instructor to restore a default VPC or choose a region with one; this demo does not create or modify VPCs."
    }
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = data.aws_vpcs.default.ids
  }
}
data "aws_subnet" "candidate" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}
# Route tables include both explicit subnet associations and the VPC main table.
data "aws_route_tables" "default" {
  vpc_id = one(data.aws_vpcs.default.ids)
}
data "aws_route_table" "candidate" {
  for_each       = toset(data.aws_route_tables.default.ids)
  route_table_id = each.value
}
data "aws_availability_zones" "standard" {
  state = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

locals {
  main_route_table = one([for id, rt in data.aws_route_table.candidate : id if anytrue([for a in rt.associations : a.main])])
  effective_route_tables = {
    for id, subnet in data.aws_subnet.candidate : id => coalesce(
      try(one([for rid, rt in data.aws_route_table.candidate : rid if anytrue([for a in rt.associations : a.subnet_id == id])]), null),
      local.main_route_table
    )
  }
  usable_subnets = {
    for id, subnet in data.aws_subnet.candidate : id => subnet
    if contains(data.aws_availability_zones.standard.names, subnet.availability_zone) &&
    subnet.available_ip_address_count >= 12 && tonumber(split("/", subnet.cidr_block)[1]) <= 27 &&
    anytrue([for r in data.aws_route_table.candidate[local.effective_route_tables[id]].routes : r.cidr_block == "0.0.0.0/0" && startswith(coalesce(r.gateway_id, "none"), "igw-")])
  }
  subnets_by_az    = { for id, subnet in local.usable_subnets : subnet.availability_zone => id... }
  selected_subnets = slice([for az in sort(keys(local.subnets_by_az)) : sort(local.subnets_by_az[az])[0]], 0, min(2, length(local.subnets_by_az)))
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.project_prefix}-alb-"
  description = "Public HTTP to the classroom ALB"
  vpc_id      = one(data.aws_vpcs.default.ids)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "tasks" {
  name_prefix = "${var.project_prefix}-tasks-"
  description = "HTTP only from the ALB; outbound image pulling"
  vpc_id      = one(data.aws_vpcs.default.ids)
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_lb" "demo" {
  name               = "${var.project_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.selected_subnets
  lifecycle {
    precondition {
      condition     = length(local.selected_subnets) == 2
      error_message = "The default VPC needs public subnets in two distinct standard AZs, each with a /27 or larger CIDR, at least 12 free IPs, and a 0.0.0.0/0 route to an Internet Gateway. Ask your instructor to repair the default network or choose another region."
    }
  }
}
resource "aws_lb_target_group" "demo" {
  name                 = "${var.project_prefix}-tg"
  port                 = 80
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = one(data.aws_vpcs.default.ids)
  deregistration_delay = 15
  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.demo.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.demo.arn
  }
}
resource "aws_ecs_cluster" "demo" {
  name = "${var.project_prefix}-cluster"
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}
resource "aws_iam_role" "execution" {
  name = "${var.project_prefix}-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_ecs_task_definition" "demo" {
  family                   = var.project_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "web"
    image        = "public.ecr.aws/docker/library/httpd:2.4"
    essential    = true
    portMappings = [{ containerPort = 80, hostPort = 80, protocol = "tcp" }]
    command      = ["/bin/sh", "-ec", "printf '<h1>AWS ECS Load Balancing Demo</h1>\\n<h2>Served by: %s</h2>\\n' \"$(hostname)\" > /usr/local/apache2/htdocs/index.html; exec httpd-foreground"]
  }])
}
resource "aws_ecs_service" "demo" {
  name                               = "${var.project_prefix}-service"
  cluster                            = aws_ecs_cluster.demo.id
  task_definition                    = aws_ecs_task_definition.demo.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60
  wait_for_steady_state              = true
  propagate_tags                     = "SERVICE"
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = local.selected_subnets
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.demo.arn
    container_name   = "web"
    container_port   = 80
  }
  timeouts {
    create = "20m"
    update = "20m"
    delete = "20m"
  }
  depends_on = [aws_lb_listener.http, aws_iam_role_policy_attachment.execution]
}

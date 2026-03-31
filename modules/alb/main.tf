# =============================================================================
# Application Load Balancer
# =============================================================================

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "prod" ? true : false
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.project_name}-alb-${var.environment}"
  }
}

# =============================================================================
# Target Group - NGINX Ingress Controller (NodePort)
# =============================================================================

resource "aws_lb_target_group" "ingress" {
  name     = "${var.project_name}-ingress-${var.environment}"
  port     = 30080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/healthz"
    port                = "30080"
    matcher             = "200"
  }

  tags = {
    Name = "${var.project_name}-ingress-tg-${var.environment}"
  }
}

# =============================================================================
# ALB Listener - HTTP (AWS Academy: sem HTTPS/ACM)
# =============================================================================

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress.arn
  }

  tags = {
    Name = "${var.project_name}-http-listener-${var.environment}"
  }
}

# =============================================================================
# Target Group Attachment via Auto Scaling Group (EKS Node Group)
# =============================================================================

resource "aws_autoscaling_attachment" "eks_nodes" {
  autoscaling_group_name = var.node_group_asg_names[0]
  lb_target_group_arn    = aws_lb_target_group.ingress.arn
}

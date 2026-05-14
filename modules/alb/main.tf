# =============================================================================
# ALB Module
# Internet-facing Application Load Balancer fronting NGINX Ingress on NodePort 30080
# Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 18.3
# =============================================================================

# =============================================================================
# Application Load Balancer — internet-facing, both public subnets (Req 8.1, 8.2)
# =============================================================================

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  # Deletion protection only in prod — Academy labs need easy teardown
  enable_deletion_protection = var.environment == "prod" ? true : false

  # Drop malformed headers — security hardening (Req 18.3)
  drop_invalid_header_fields = true

  # Access logs to Access_Logs_Bucket under prefix alb/ (Req 8.6)
  access_logs {
    bucket  = var.access_logs_bucket_id
    prefix  = "alb"
    enabled = true
  }

  tags = {
    Name        = "${var.project_name}-alb-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# Target Group — NGINX Ingress Controller on NodePort 30080 (Req 8.3, 8.4, 8.5)
# HTTP health check on /healthz; healthy=2, unhealthy=2
# =============================================================================

resource "aws_lb_target_group" "ingress" {
  name     = "${var.project_name}-ingress-${var.environment}"
  port     = 30080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/healthz"
    port                = "30080"
    protocol            = "HTTP"
    matcher             = "200"
  }

  tags = {
    Name        = "${var.project_name}-ingress-tg-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# HTTP Listener — port 80 forwarding to NGINX Ingress TG (Req 8.2)
# No HTTPS listener — AWS Academy has no ACM public cert validation
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
    Name        = "${var.project_name}-http-listener-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# ASG Attachments — attach ALL EKS node group ASGs to the target group (Req 8.3)
# Uses count based on expected_asg_count (known at plan time) to avoid
# for_each unknown-value limitation with EKS-derived ASG names.
# =============================================================================

resource "aws_autoscaling_attachment" "eks_nodes" {
  count = var.expected_asg_count

  autoscaling_group_name = var.node_group_asg_names[count.index]
  lb_target_group_arn    = aws_lb_target_group.ingress.arn
}

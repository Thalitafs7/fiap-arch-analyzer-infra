output "alb_dns_name" {
  description = "DNS name of the ALB — consumed by k8s-config as ALB_DNS_NAME in infra-outputs ConfigMap"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ARN of the ALB"
  value       = aws_lb.main.arn
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB (useful for Route53 alias records)"
  value       = aws_lb.main.zone_id
}

output "target_group_arn" {
  description = "ARN of the NGINX Ingress target group"
  value       = aws_lb_target_group.ingress.arn
}

output "http_listener_arn" {
  description = "ARN of the HTTP listener on port 80"
  value       = aws_lb_listener.http.arn
}

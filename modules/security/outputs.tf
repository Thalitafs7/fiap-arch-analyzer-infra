output "alb_security_group_id" {
  description = "ID of the ALB security group (ingress TCP/80 from alb_ingress_cidrs)"
  value       = aws_security_group.alb.id
}

output "eks_nodes_security_group_id" {
  description = "ID of the EKS nodes security group (NodePort from ALB SG; egress TCP/80+443)"
  value       = aws_security_group.eks_nodes.id
}

output "rds_security_group_id" {
  description = "ID of the RDS security group (ingress TCP/5432 from EKS nodes SG only)"
  value       = aws_security_group.rds.id
}

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint URL of the EKS cluster API server"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority" {
  description = "Base64-encoded certificate authority data for the cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group ID automatically created by EKS for the cluster control plane"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "node_group_asg_names" {
  description = "Auto Scaling Group names associated with the managed node group"
  value       = aws_eks_node_group.main.resources[0].autoscaling_groups[*].name
}

# ---------------------------------------------------------------------------
# Additional convenience outputs (not required by task spec but useful for
# root main.tf wiring and the ALB / k8s-config modules)
# ---------------------------------------------------------------------------

output "node_group_name" {
  description = "Name of the managed node group"
  value       = aws_eks_node_group.main.node_group_name
}

output "cluster_version" {
  description = "Kubernetes version of the cluster"
  value       = aws_eks_cluster.main.version
}

output "kubeconfig_command" {
  description = "AWS CLI command to update kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

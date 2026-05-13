# =============================================================================
# KMS Key for EKS Secrets Encryption (CMK path)
# Skipped when use_aws_managed_kms=true — falls back to alias/aws/eks.
# In AWS Academy, kms:CreateKey is sometimes denied; set use_aws_managed_kms=true
# in that case to avoid apply failures.
# =============================================================================

resource "aws_kms_key" "eks" {
  count = var.use_aws_managed_kms ? 0 : 1

  description             = "CMK for EKS secrets encryption - ${var.project_name}-${var.environment}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-eks-kms-${var.environment}"
  }
}

resource "aws_kms_alias" "eks" {
  count = var.use_aws_managed_kms ? 0 : 1

  name          = "alias/${var.project_name}-eks-${var.environment}"
  target_key_id = aws_kms_key.eks[0].key_id
}

locals {
  # When use_aws_managed_kms=true (or CMK creation is skipped), use the
  # AWS-managed EKS key. Otherwise use the CMK ARN.
  # Requirements 7.7, 18.7
  kms_key_arn = var.use_aws_managed_kms ? "alias/aws/eks" : aws_kms_key.eks[0].arn
}

# =============================================================================
# CloudWatch Log Group for EKS Control Plane Logs
# =============================================================================

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.project_name}-${var.environment}/cluster"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-eks-logs-${var.environment}"
  }
}

# =============================================================================
# EKS Cluster
# Requirements: 7.1, 7.2, 7.3, 18.1, 18.2
# =============================================================================

resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-${var.environment}"
  version  = var.cluster_version
  role_arn = var.lab_role_arn

  vpc_config {
    subnet_ids              = concat(var.public_subnet_ids, var.private_subnet_ids)
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    # Restrict public API endpoint to student workstation CIDRs (Req 7.3)
    public_access_cidrs = var.eks_public_access_cidrs
    security_group_ids  = []
  }

  # Only api, audit, authenticator per task spec (Req 7.2)
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Only enable encryption_config when a real CMK is available (not AWS Academy)
  dynamic "encryption_config" {
    for_each = var.use_aws_managed_kms ? [] : [1]
    content {
      provider {
        key_arn = aws_kms_key.eks[0].arn
      }
      resources = ["secrets"]
    }
  }

  tags = {
    Name = "${var.project_name}-eks-${var.environment}"
  }

  depends_on = [
    aws_cloudwatch_log_group.eks,
  ]
}

# =============================================================================
# Launch Template — attaches eks_nodes_security_group to node instances
# Requirements: 7.6
# =============================================================================

resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${var.project_name}-eks-nodes-${var.environment}-"
  description = "Launch template for EKS managed node group - ${var.project_name}-${var.environment}"

  # Attach the security group produced by the security module + EKS cluster SG
  # The cluster SG is required for node-to-control-plane communication
  vpc_security_group_ids = [var.eks_nodes_security_group_id, aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]

  # Optional SSH key for node access
  key_name = var.ssh_key_name != "" ? var.ssh_key_name : null

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional" # IMDSv1 required for LabRole IMDS credential fetch
    http_put_response_hop_limit = 2          # allows pods to reach IMDS via node
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-eks-node-${var.environment}"
      environment = var.environment
      project     = var.project_name
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# EKS Managed Node Group
# Requirements: 7.4, 7.5, 7.6, 18.5
# =============================================================================

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes-${var.environment}"
  node_role_arn   = var.lab_role_arn
  subnet_ids      = var.public_subnet_ids

  # Nodes in public subnets — avoids NAT Gateway cost (design decision)
  instance_types = var.node_instance_types
  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  # Attach security group via launch template (Req 7.6)
  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  labels = {
    environment = var.environment
    project     = var.project_name
  }

  tags = {
    Name = "${var.project_name}-eks-node-${var.environment}"
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_eks_cluster.main]
}

# =============================================================================
# EKS Addons
# =============================================================================

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${var.project_name}-vpc-cni-${var.environment}"
  }

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${var.project_name}-coredns-${var.environment}"
  }

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${var.project_name}-kube-proxy-${var.environment}"
  }

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = var.lab_role_arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${var.project_name}-ebs-csi-${var.environment}"
  }

  depends_on = [aws_eks_node_group.main]
}

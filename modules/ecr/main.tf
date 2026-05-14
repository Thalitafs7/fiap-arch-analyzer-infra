# =============================================================================
# ECR Repositories
# =============================================================================

resource "aws_ecr_repository" "repos" {
  for_each = toset(var.repository_names)

  name                 = "${var.project_name}-${each.value}"
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.project_name}-${each.value}-${var.environment}"
  }
}

# =============================================================================
# Lifecycle Policy - manter apenas as últimas N imagens
# =============================================================================

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each = aws_ecr_repository.repos

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last ${var.max_image_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# =============================================================================
# Repository Policy - permite push/pull pelo LabRole e pelo EKS node role
# =============================================================================
# No AWS Academy, não é possível criar IAM roles customizadas.
# A política de repositório ECR é o mecanismo correto para garantir que
# o LabRole (usado pelo CI/CD e pelo deploy-all.ps1) possa fazer push,
# e que os nodes EKS (também usando LabRole) possam fazer pull.
# =============================================================================

data "aws_caller_identity" "current" {}

resource "aws_ecr_repository_policy" "repos" {
  for_each = aws_ecr_repository.repos

  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLabRolePushPull"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:GetRepositoryPolicy",
          "ecr:ListImages",
          "ecr:DeleteRepository",
          "ecr:BatchDeleteImage",
          "ecr:SetRepositoryPolicy",
          "ecr:DeleteRepositoryPolicy"
        ]
      }
    ]
  })
}

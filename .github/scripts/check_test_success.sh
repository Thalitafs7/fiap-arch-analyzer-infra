#!/bin/bash
set -e

echo "Starting Terraform validation..."

# Initialize Terraform (needed for validation)
terraform init -backend=false

# Check formatting
echo "Checking Terraform formatting..."
terraform fmt -check -recursive

# Validate configuration
echo "Validating Terraform configuration..."
terraform validate

echo "Terraform validation successful!"

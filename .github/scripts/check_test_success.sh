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
echo "Starting Terraform checks..."

# 1. Terraform Init
echo "Running: terraform init"
terraform init -backend=false

# 2. Terraform Format Check
echo "Running: terraform fmt -check"
terraform fmt -check -recursive

# 3. Terraform Validate
echo "Running: terraform validate"
terraform validate

echo "All Terraform checks passed successfully!"

#!/bin/bash
if command -v terraform &> /dev/null
then
    echo "Terraform is installed"
    terraform --version
else
    echo "Terraform is NOT installed"
fi

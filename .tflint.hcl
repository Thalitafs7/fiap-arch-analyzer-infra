plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

config {
  format              = "default"
  call_module_type    = "local"
  force               = false
  disabled_by_default = false
}

# Enforce naming conventions
rule "terraform_naming_convention" {
  enabled = true
}

# Require all variables to have descriptions
rule "terraform_documented_variables" {
  enabled = true
}

# Require all outputs to have descriptions
rule "terraform_documented_outputs" {
  enabled = true
}

# Disallow deprecated interpolation syntax
rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Require type constraints on variables
rule "terraform_typed_variables" {
  enabled = true
}

# Warn on unused declarations
rule "terraform_unused_declarations" {
  enabled = true
}

# Require required_providers block
rule "terraform_required_providers" {
  enabled = true
}

# Require required_version constraint
rule "terraform_required_version" {
  enabled = true
}

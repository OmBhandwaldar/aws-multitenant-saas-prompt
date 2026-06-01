terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

locals {
  pool_name   = "${var.project_name}-${var.environment}-pool"
  client_name = "${var.project_name}-${var.environment}-client"
}

###############################################################################
# User pool with two immutable-after-create custom attributes:
#   custom:tenant_id  — never mutates (mutable=false)
#   custom:role       — admin | member (mutable=true so admins can promote)
#
# Standard attributes: email (required, verified), name. Username is the
# Cognito sub (auto-generated UUID); login alias is the email.
###############################################################################
resource "aws_cognito_user_pool" "this" {
  name = local.pool_name

  username_attributes      = ["email"]
  auto_verified_attributes = var.auto_confirm_signups ? [] : ["email"]
  mfa_configuration        = "OFF"
  deletion_protection      = var.deletion_protection ? "ACTIVE" : "INACTIVE"

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  user_pool_add_ons {
    advanced_security_mode = var.advanced_security
  }

  schema {
    name                     = "email"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 5
      max_length = 256
    }
  }

  schema {
    name                     = "name"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = false
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 1
      max_length = 128
    }
  }

  schema {
    name                     = "tenant_id"
    attribute_data_type      = "String"
    mutable                  = false
    required                 = false
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  schema {
    name                     = "role"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = false
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 1
      max_length = 32
    }
  }

  lifecycle {
    # The schema block cannot be modified once the pool exists.
    # If you need new custom attributes, add them as a separate schema
    # block via aws_cognito_user_pool_schema (provider >= 5.40 only).
    ignore_changes = []
  }
}

###############################################################################
# App client used by the tenant_signup Lambda and by end-user authentication
# flows. No client secret (browser/mobile cannot keep it).
#
# Auth flows:
#   USER_PASSWORD_AUTH    — admin sign-in (initiate-auth from the CLI)
#   REFRESH_TOKEN_AUTH    — refresh access/ID tokens
#
# Token expiry: access 1h, id 1h, refresh 30d. Custom attributes flow into
# the access token because we list them in read_attributes.
###############################################################################
resource "aws_cognito_user_pool_client" "this" {
  name         = local.client_name
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret               = false
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]

  access_token_validity  = 60   # minutes
  id_token_validity      = 60   # minutes
  refresh_token_validity = 30   # days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  read_attributes = [
    "email",
    "email_verified",
    "name",
    "custom:tenant_id",
    "custom:role",
  ]

  write_attributes = [
    "email",
    "name",
  ]
}

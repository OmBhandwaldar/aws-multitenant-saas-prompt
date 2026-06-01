terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  backend "s3" {
    key     = "saas-starter/prod/terraform.tfstate"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "Terraform"
      CostCenter  = var.cost_center
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "data" {
  source = "../../modules/data"

  project_name = var.project_name
  environment  = var.environment
}

module "cognito" {
  source = "../../modules/cognito"

  project_name         = var.project_name
  environment          = var.environment
  auto_confirm_signups = var.auto_confirm_signups
  advanced_security    = var.cognito_advanced_security
  deletion_protection  = true
}

module "authorizer" {
  source = "../../modules/authorizer"

  project_name         = var.project_name
  environment          = var.environment
  aws_region           = var.aws_region
  user_pool_id         = module.cognito.user_pool_id
  user_pool_client_id  = module.cognito.user_pool_client_id
  app_table_arn        = module.data.app_table_arn
  log_retention_days   = var.log_retention_days
  log_level            = var.log_level
  reserved_concurrency = var.authorizer_reserved_concurrency
  sts_duration_seconds = var.sts_duration_seconds
}

module "tenant_signup" {
  source = "../../modules/tenant_signup"

  project_name         = var.project_name
  environment          = var.environment
  user_pool_id         = module.cognito.user_pool_id
  user_pool_client_id  = module.cognito.user_pool_client_id
  app_table_name       = module.data.app_table_name
  app_table_arn        = module.data.app_table_arn
  log_retention_days   = var.log_retention_days
  log_level            = var.log_level
  reserved_concurrency = var.business_reserved_concurrency
  auto_confirm_signups = var.auto_confirm_signups
}

module "business" {
  source = "../../modules/business"

  project_name         = var.project_name
  environment          = var.environment
  aws_region           = var.aws_region
  entity_types         = var.entity_types
  app_table_name       = module.data.app_table_name
  app_table_arn        = module.data.app_table_arn
  user_pool_id         = module.cognito.user_pool_id
  log_retention_days   = var.log_retention_days
  log_level            = var.log_level
  reserved_concurrency = var.business_reserved_concurrency
}

module "api" {
  source = "../../modules/api"

  project_name                = var.project_name
  environment                 = var.environment
  authorizer_invoke_arn       = module.authorizer.invoke_arn
  authorizer_function_name    = module.authorizer.function_name
  authorizer_result_ttl       = var.authorizer_result_ttl
  tenant_signup_invoke_arn    = module.tenant_signup.invoke_arn
  tenant_signup_function_name = module.tenant_signup.function_name
  business_lambdas            = module.business.lambdas
  entity_types                = var.entity_types
  log_retention_days          = var.log_retention_days
  throttling_burst_limit      = var.api_throttling_burst_limit
  throttling_rate_limit       = var.api_throttling_rate_limit
  enable_custom_domain        = var.enable_custom_domain
  custom_domain               = var.custom_domain
  hosted_zone_name            = var.hosted_zone_name
  enable_waf                  = var.enable_waf
  waf_rate_limit              = var.waf_rate_limit
}

module "observability" {
  source = "../../modules/observability"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  alert_email                 = var.alert_email
  authorizer_function_name    = module.authorizer.function_name
  tenant_signup_function_name = module.tenant_signup.function_name
  business_function_names     = module.business.function_names
  app_table_name              = module.data.app_table_name
  api_name                    = module.api.api_name
  api_stage_name              = module.api.stage_name
  user_pool_id                = module.cognito.user_pool_id
}

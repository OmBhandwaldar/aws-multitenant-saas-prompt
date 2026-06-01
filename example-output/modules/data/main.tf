terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

###############################################################################
# Single-table design.
#
# PK pattern: TENANT#<tenant_id>
# SK patterns:
#   META#TENANT                       — the tenant record itself
#   USER#<cognito_sub>                — a user belonging to the tenant
#   ENTITY#<entity_type>#<entity_id>  — business entities
#   IDEMPOTENCY#<key>                 — signup idempotency markers (TTL)
#
# GSI1 (sparse) groups entities by type within a tenant, sorted by created_at,
# so we can answer "list all projects for tenant X ordered by creation date"
# with a single Query.
#   GSI1PK = TENANT#<tenant_id>#<entity_type>
#   GSI1SK = <created_at_iso>
#
# The dynamodb:LeadingKeys session-policy condition pattern works *because*
# every item's PK starts with TENANT#<tenant_id> — this is the architectural
# invariant the entire isolation guarantee rests on.
###############################################################################
resource "aws_dynamodb_table" "app" {
  name         = "${var.project_name}-${var.environment}-app"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "GSI1PK"
    type = "S"
  }

  attribute {
    name = "GSI1SK"
    type = "S"
  }

  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = var.environment == "prod"
}

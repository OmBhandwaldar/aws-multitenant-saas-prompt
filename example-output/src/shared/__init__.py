"""Shared helpers for SaaS Lambdas.

Public surface:
    auth     — JWT helpers, @require_role decorator, response helpers
    ddb      — tenant-scoped boto3 client built from authorizer credentials
    logging  — structured logger that auto-injects tenant_id
    metrics  — CloudWatch EMF metrics with tenant_id dimension
"""

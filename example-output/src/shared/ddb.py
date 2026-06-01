"""Tenant-scoped DynamoDB client builder.

Business Lambdas use ONLY :func:`get_tenant_client` (or the resource variant).
They MUST NOT fall back to the default boto3 credential chain — doing so would
silently bypass Layer 2 isolation (the session-policy restriction on
``dynamodb:LeadingKeys``) and run with the Lambda's own execution-role
credentials (which have *no* DynamoDB permissions, so the call would fail
loudly — but the discipline is to use only this helper).
"""

from __future__ import annotations

import os
from typing import Any

import boto3
from botocore.config import Config

from shared.auth import get_tenant_credentials, get_tenant_id

_REGION = os.environ.get("AWS_REGION_NAME") or os.environ.get("AWS_REGION") or "us-east-1"
_BOTO_CONFIG = Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=2, read_timeout=5)


def get_tenant_client(event: dict[str, Any]):
    """Return a low-level boto3 DynamoDB client signed with tenant credentials."""
    creds = get_tenant_credentials(event)
    return boto3.client(
        "dynamodb",
        region_name=_REGION,
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        config=_BOTO_CONFIG,
    )


def get_tenant_resource(event: dict[str, Any]):
    """Return a boto3 DynamoDB resource signed with tenant credentials (Table objects)."""
    creds = get_tenant_credentials(event)
    return boto3.resource(
        "dynamodb",
        region_name=_REGION,
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        config=_BOTO_CONFIG,
    )


def tenant_pk(event: dict[str, Any]) -> str:
    """Convenience: TENANT#<tenant_id>."""
    return f"TENANT#{get_tenant_id(event)}"


def entity_sk(entity_type: str, entity_id: str) -> str:
    return f"ENTITY#{entity_type}#{entity_id}"


def gsi1_pk(tenant_id: str, entity_type: str) -> str:
    return f"TENANT#{tenant_id}#{entity_type}"

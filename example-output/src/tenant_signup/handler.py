"""POST /tenants/signup — public route.

Body:
    {
      "tenant_name": "Acme Inc",
      "admin_email": "founder@acme.example",
      "admin_password": "Sup3r$ecret-12!",
      "admin_name": "Jane Founder",
      "idempotency_key": "optional-client-supplied-uuid"
    }

Behavior:
    1. Generate tenant_id (uuid4).
    2. Create a Cognito user with custom:tenant_id and custom:role=admin.
       Permanent password set via AdminSetUserPassword.
       Auto-confirm in dev; require email verification in prod.
    3. TransactWriteItems:
        - tenant META record (PK=TENANT#<tid>, SK=META#TENANT)
        - admin USER record (PK=TENANT#<tid>, SK=USER#<sub>)
        - idempotency marker (PK=IDEMPOTENCY#<key>, SK=META, TTL 24h)
    4. Return {tenant_id, admin_email} — never returns a JWT; client signs in
       via Cognito normally.

Atomicity: the TransactWriteItems guarantees both records exist or neither.
On Cognito create-failure after the user is created (unlikely), we delete
the user to keep the system consistent.
"""

from __future__ import annotations

import json
import os
import time
import uuid
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from botocore.config import Config
from botocore.exceptions import ClientError

from shared.auth import error, parse_body, response, AuthError

PROJECT_NAME = os.environ["PROJECT_NAME"]
ENVIRONMENT = os.environ["ENVIRONMENT"]
USER_POOL_ID = os.environ["USER_POOL_ID"]
USER_POOL_CLIENT_ID = os.environ["USER_POOL_CLIENT_ID"]
APP_TABLE_NAME = os.environ["APP_TABLE_NAME"]
AUTO_CONFIRM_SIGNUPS = os.environ.get("AUTO_CONFIRM_SIGNUPS", "false").lower() == "true"
IDEMPOTENCY_TTL_SECONDS = int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", "86400"))

logger = Logger(service="saas-tenant-signup")
tracer = Tracer(service="saas-tenant-signup")
metrics = Metrics(namespace=f"{PROJECT_NAME}/{ENVIRONMENT}", service="saas-tenant-signup")

_cfg = Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=2, read_timeout=5)
_cognito = boto3.client("cognito-idp", config=_cfg)
_ddb = boto3.client("dynamodb", config=_cfg)


def _validate_input(body: dict[str, Any]) -> dict[str, str]:
    required = ["tenant_name", "admin_email", "admin_password"]
    missing = [k for k in required if not body.get(k)]
    if missing:
        raise AuthError(f"missing required field(s): {missing}")
    return {
        "tenant_name": str(body["tenant_name"]).strip(),
        "admin_email": str(body["admin_email"]).strip().lower(),
        "admin_password": str(body["admin_password"]),
        "admin_name": str(body.get("admin_name") or "").strip(),
        "idempotency_key": str(body.get("idempotency_key") or "").strip(),
    }


def _create_cognito_admin(tenant_id: str, email: str, password: str, name: str) -> str:
    """Create the admin Cognito user and return its sub."""
    attrs = [
        {"Name": "email", "Value": email},
        {"Name": "email_verified", "Value": "true" if AUTO_CONFIRM_SIGNUPS else "false"},
        {"Name": "custom:tenant_id", "Value": tenant_id},
        {"Name": "custom:role", "Value": "admin"},
    ]
    if name:
        attrs.append({"Name": "name", "Value": name})

    resp = _cognito.admin_create_user(
        UserPoolId=USER_POOL_ID,
        Username=email,
        UserAttributes=attrs,
        MessageAction="SUPPRESS" if AUTO_CONFIRM_SIGNUPS else "RESEND",
        DesiredDeliveryMediums=["EMAIL"],
    )
    sub = ""
    for a in resp["User"]["Attributes"]:
        if a["Name"] == "sub":
            sub = a["Value"]
            break
    if not sub:
        raise RuntimeError("Cognito did not return a sub for the new user")

    # Set permanent password (admin_create_user defaults to temporary).
    _cognito.admin_set_user_password(
        UserPoolId=USER_POOL_ID,
        Username=email,
        Password=password,
        Permanent=True,
    )

    if AUTO_CONFIRM_SIGNUPS:
        # Mark confirmed without requiring the email-verification flow.
        try:
            _cognito.admin_update_user_attributes(
                UserPoolId=USER_POOL_ID,
                Username=email,
                UserAttributes=[{"Name": "email_verified", "Value": "true"}],
            )
        except ClientError:
            logger.warning("could not mark email_verified=true (non-fatal)")

    return sub


def _write_records(tenant_id: str, tenant_name: str, admin_sub: str, admin_email: str, admin_name: str, idempotency_key: str) -> None:
    now = int(time.time())
    iso_now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))

    items = [
        {
            "Put": {
                "TableName": APP_TABLE_NAME,
                "Item": {
                    "PK": {"S": f"TENANT#{tenant_id}"},
                    "SK": {"S": "META#TENANT"},
                    "tenant_id": {"S": tenant_id},
                    "tenant_name": {"S": tenant_name},
                    "created_at": {"S": iso_now},
                    "status": {"S": "active"},
                },
                "ConditionExpression": "attribute_not_exists(PK)",
            }
        },
        {
            "Put": {
                "TableName": APP_TABLE_NAME,
                "Item": {
                    "PK": {"S": f"TENANT#{tenant_id}"},
                    "SK": {"S": f"USER#{admin_sub}"},
                    "tenant_id": {"S": tenant_id},
                    "user_id": {"S": admin_sub},
                    "email": {"S": admin_email},
                    "name": {"S": admin_name},
                    "role": {"S": "admin"},
                    "created_at": {"S": iso_now},
                },
                "ConditionExpression": "attribute_not_exists(PK)",
            }
        },
    ]

    if idempotency_key:
        items.append(
            {
                "Put": {
                    "TableName": APP_TABLE_NAME,
                    "Item": {
                        "PK": {"S": f"IDEMPOTENCY#{idempotency_key}"},
                        "SK": {"S": "META"},
                        "tenant_id": {"S": tenant_id},
                        "created_at": {"S": iso_now},
                        "ttl": {"N": str(now + IDEMPOTENCY_TTL_SECONDS)},
                    },
                    "ConditionExpression": "attribute_not_exists(PK)",
                }
            }
        )

    _ddb.transact_write_items(TransactItems=items)


def _check_idempotency_replay(idempotency_key: str) -> str | None:
    """If the key already exists, return the previously-created tenant_id."""
    if not idempotency_key:
        return None
    resp = _ddb.get_item(
        TableName=APP_TABLE_NAME,
        Key={"PK": {"S": f"IDEMPOTENCY#{idempotency_key}"}, "SK": {"S": "META"}},
        ConsistentRead=True,
    )
    item = resp.get("Item")
    if item:
        return item.get("tenant_id", {}).get("S")
    return None


@metrics.log_metrics(capture_cold_start_metric=True)
@tracer.capture_lambda_handler
@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    try:
        body = parse_body(event)
        data = _validate_input(body)
    except AuthError as exc:
        return error(400, "bad_request", str(exc))

    # Idempotency replay
    replay_tid = _check_idempotency_replay(data["idempotency_key"])
    if replay_tid:
        logger.info("idempotency replay", extra={"tenant_id": replay_tid})
        metrics.add_metric(name="SignupIdempotencyHit", unit=MetricUnit.Count, value=1)
        return response(200, {"tenant_id": replay_tid, "admin_email": data["admin_email"], "replay": True})

    tenant_id = str(uuid.uuid4())
    logger.append_keys(tenant_id=tenant_id, admin_email=data["admin_email"])

    # 1. Create Cognito user.
    try:
        sub = _create_cognito_admin(tenant_id, data["admin_email"], data["admin_password"], data["admin_name"])
    except _cognito.exceptions.UsernameExistsException:
        return error(409, "user_exists", f"a user with email {data['admin_email']} already exists")
    except ClientError as exc:
        logger.exception("cognito create failed")
        metrics.add_metric(name="SignupCognitoError", unit=MetricUnit.Count, value=1)
        return error(500, "cognito_error", exc.response.get("Error", {}).get("Message", "cognito failure"))

    # 2. Atomically write tenant + admin user (+ idempotency marker).
    try:
        _write_records(
            tenant_id=tenant_id,
            tenant_name=data["tenant_name"],
            admin_sub=sub,
            admin_email=data["admin_email"],
            admin_name=data["admin_name"],
            idempotency_key=data["idempotency_key"],
        )
    except ClientError as exc:
        logger.exception("ddb transact write failed; rolling back Cognito user")
        try:
            _cognito.admin_delete_user(UserPoolId=USER_POOL_ID, Username=data["admin_email"])
        except ClientError:
            logger.exception("rollback delete_user failed — manual cleanup required")
        metrics.add_metric(name="SignupDDBError", unit=MetricUnit.Count, value=1)
        return error(500, "ddb_error", exc.response.get("Error", {}).get("Message", "ddb failure"))

    logger.info("tenant created")
    metrics.add_metric(name="SignupSuccess", unit=MetricUnit.Count, value=1)
    return response(
        201,
        {
            "tenant_id": tenant_id,
            "admin_email": data["admin_email"],
            "user_id": sub,
            "next_steps": [
                "Sign in with InitiateAuth (USER_PASSWORD_AUTH) using the admin_email and password to obtain a JWT.",
                "Pass the access token in the Authorization header on subsequent API calls.",
            ],
        },
    )

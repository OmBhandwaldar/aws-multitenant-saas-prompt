"""Admin-only user management within a tenant.

Routes:
    GET    /users           — list users in the caller's tenant (Query on PK + SK begins_with USER#)
    POST   /users           — invite a new user. Cognito user is created with
                              custom:tenant_id = caller's tenant_id (NOT from the body)
                              and the role from the body (defaults to "member").
    DELETE /users/{id}      — delete a user. Refuses to delete the last admin.

Admin enforcement happens via @require_role("admin"). Members get 403.

This Lambda is special: it has cognito-idp:AdminCreateUser on its execution role
because the Cognito Admin APIs cannot be invoked with the per-request tenant
STS credentials (those are scoped to DynamoDB, not Cognito). The discipline:
this Lambda still reads tenant_id from the authorizer context only — never the
body — so a member cannot trick it into creating a user in another tenant.
"""

from __future__ import annotations

import os
import time
import uuid
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from botocore.config import Config
from botocore.exceptions import ClientError

from shared.auth import (
    AuthError,
    error,
    get_tenant_id,
    get_user_id,
    parse_body,
    require_role,
    response,
)
from shared.ddb import get_tenant_client, tenant_pk
from shared.logging import bind_tenant_keys
from shared.metrics import emit_request

PROJECT_NAME = os.environ["PROJECT_NAME"]
ENVIRONMENT = os.environ["ENVIRONMENT"]
APP_TABLE_NAME = os.environ["APP_TABLE_NAME"]
USER_POOL_ID = os.environ["USER_POOL_ID"]
FUNCTION_NAME = os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "unknown")

logger = Logger(service="saas-users")
tracer = Tracer(service="saas-users")
metrics = Metrics(namespace=f"{PROJECT_NAME}/{ENVIRONMENT}", service="saas-users")

_cfg = Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=2, read_timeout=5)
_cognito = boto3.client("cognito-idp", config=_cfg)


def _iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _list_users(event: dict[str, Any]) -> dict[str, Any]:
    ddb = get_tenant_client(event)
    resp = ddb.query(
        TableName=APP_TABLE_NAME,
        KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
        ExpressionAttributeValues={
            ":pk": {"S": tenant_pk(event)},
            ":sk": {"S": "USER#"},
        },
    )
    items = []
    for raw in resp.get("Items", []):
        items.append(
            {
                "user_id": raw.get("user_id", {}).get("S", ""),
                "email": raw.get("email", {}).get("S", ""),
                "name": raw.get("name", {}).get("S", ""),
                "role": raw.get("role", {}).get("S", "member"),
                "created_at": raw.get("created_at", {}).get("S", ""),
            }
        )
    return response(200, {"items": items, "count": len(items)})


@require_role("admin")
def _invite_user(event: dict[str, Any]) -> dict[str, Any]:
    tid = get_tenant_id(event)
    body = parse_body(event)
    email = (body.get("email") or "").strip().lower()
    name = (body.get("name") or "").strip()
    role = (body.get("role") or "member").strip().lower()
    if not email:
        raise AuthError("email is required")
    if role not in {"admin", "member"}:
        raise AuthError("role must be 'admin' or 'member'")

    # 1. Create the Cognito user. AdminCreateUser sends an invitation email
    # with a temporary password — the user resets on first sign-in. Note:
    # tenant_id is taken from the authorizer context, NEVER from the body.
    try:
        cresp = _cognito.admin_create_user(
            UserPoolId=USER_POOL_ID,
            Username=email,
            UserAttributes=[
                {"Name": "email", "Value": email},
                {"Name": "email_verified", "Value": "true"},
                {"Name": "name", "Value": name} if name else {"Name": "name", "Value": email.split("@")[0]},
                {"Name": "custom:tenant_id", "Value": tid},
                {"Name": "custom:role", "Value": role},
            ],
            DesiredDeliveryMediums=["EMAIL"],
        )
    except _cognito.exceptions.UsernameExistsException:
        return error(409, "user_exists", f"a user with email {email} already exists")

    sub = ""
    for a in cresp["User"]["Attributes"]:
        if a["Name"] == "sub":
            sub = a["Value"]
            break

    # 2. Write the USER record into the tenant's DDB partition.
    ddb = get_tenant_client(event)
    now = _iso_now()
    try:
        ddb.put_item(
            TableName=APP_TABLE_NAME,
            Item={
                "PK": {"S": tenant_pk(event)},
                "SK": {"S": f"USER#{sub}"},
                "tenant_id": {"S": tid},
                "user_id": {"S": sub},
                "email": {"S": email},
                "name": {"S": name},
                "role": {"S": role},
                "created_at": {"S": now},
            },
            ConditionExpression="attribute_not_exists(PK)",
        )
    except ClientError:
        # Rollback the Cognito user so we don't leave orphans.
        logger.exception("ddb put_item for new user failed; rolling back Cognito user")
        try:
            _cognito.admin_delete_user(UserPoolId=USER_POOL_ID, Username=email)
        except ClientError:
            logger.exception("rollback delete_user failed — manual cleanup required")
        raise

    return response(
        201,
        {
            "user_id": sub,
            "email": email,
            "name": name,
            "role": role,
        },
    )


@require_role("admin")
def _delete_user(event: dict[str, Any], user_id: str) -> dict[str, Any]:
    caller_uid = get_user_id(event)
    if user_id == caller_uid:
        return error(400, "cannot_delete_self", "you cannot delete your own account")

    ddb = get_tenant_client(event)
    # Look up the target user record (also verifies they're in this tenant).
    target = ddb.get_item(
        TableName=APP_TABLE_NAME,
        Key={"PK": {"S": tenant_pk(event)}, "SK": {"S": f"USER#{user_id}"}},
        ConsistentRead=True,
    ).get("Item")
    if not target:
        return error(404, "not_found", f"user {user_id} not found in this tenant")

    target_email = target.get("email", {}).get("S", "")
    target_role = target.get("role", {}).get("S", "member")

    # If the target is an admin, ensure at least one other admin remains.
    if target_role == "admin":
        listing = ddb.query(
            TableName=APP_TABLE_NAME,
            KeyConditionExpression="PK = :pk AND begins_with(SK, :sk)",
            ExpressionAttributeValues={
                ":pk": {"S": tenant_pk(event)},
                ":sk": {"S": "USER#"},
            },
        )
        admins = [
            i for i in listing.get("Items", [])
            if i.get("role", {}).get("S") == "admin"
        ]
        if len(admins) <= 1:
            return error(400, "last_admin", "cannot delete the last admin of the tenant")

    # Delete DDB first, then Cognito. If Cognito fails, we have a dangling
    # Cognito user — log loudly. If DDB fails, the Cognito user is intact.
    ddb.delete_item(
        TableName=APP_TABLE_NAME,
        Key={"PK": {"S": tenant_pk(event)}, "SK": {"S": f"USER#{user_id}"}},
    )
    try:
        _cognito.admin_delete_user(UserPoolId=USER_POOL_ID, Username=target_email)
    except ClientError:
        logger.exception("cognito admin_delete_user failed AFTER ddb delete — manual cleanup required")
        return error(500, "cognito_error", "user removed from app data but Cognito deletion failed")

    return response(204, None)


@metrics.log_metrics(capture_cold_start_metric=True)
@tracer.capture_lambda_handler
@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    bind_tenant_keys(logger, event)
    method = (event.get("httpMethod") or "").upper()
    path_params = event.get("pathParameters") or {}
    target_id = path_params.get("id")
    route = "/users" + ("/{id}" if target_id else "")

    tracer.put_annotation(key="tenant_id", value=get_tenant_id(event))

    try:
        if method == "GET" and not target_id:
            resp = _list_users(event)
        elif method == "POST" and not target_id:
            resp = _invite_user(event)
        elif method == "DELETE" and target_id:
            resp = _delete_user(event, target_id)
        else:
            resp = error(405, "method_not_allowed", f"{method} {route}")
    except AuthError as exc:
        resp = error(400, "bad_request", str(exc))
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "AccessDeniedException":
            logger.error("LAYER-2 ISOLATION TRIPPED", extra={"aws_error_code": code})
            metrics.add_metric(name="Layer2Denied", unit=MetricUnit.Count, value=1)
            resp = error(403, "forbidden", "operation rejected by tenant isolation policy")
        else:
            logger.exception("aws error")
            resp = error(500, "aws_error", code or "aws failure")
    except Exception:
        logger.exception("unhandled error")
        resp = error(500, "internal_error", "unexpected failure")

    emit_request(
        metrics=metrics,
        tenant_id=get_tenant_id(event),
        route=route,
        method=method,
        function_name=FUNCTION_NAME,
        status=resp.get("statusCode", 500),
    )
    return resp

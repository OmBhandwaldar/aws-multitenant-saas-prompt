"""CRUD handler for the `projects` entity.

Routes (path-based dispatch from API Gateway):
    GET    /projects        — list projects (Query on GSI1)
    POST   /projects        — create a project
    GET    /projects/{id}   — fetch one project
    PATCH  /projects/{id}   — partial update
    DELETE /projects/{id}   — delete

Layer 1 isolation: tenant_id is read from the authorizer context ONLY.
Layer 2 isolation: the boto3 DDB client is signed with STS credentials whose
session policy restricts LeadingKeys to TENANT#<tenant_id>. A bug that tried
to read another tenant's PK would receive AccessDeniedException from DynamoDB.
"""

from __future__ import annotations

import os
import time
import uuid
from typing import Any

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from botocore.exceptions import ClientError

from shared.auth import (
    AuthError,
    error,
    get_tenant_id,
    parse_body,
    response,
)
from shared.ddb import entity_sk, get_tenant_client, gsi1_pk, tenant_pk
from shared.logging import bind_tenant_keys
from shared.metrics import emit_request

PROJECT_NAME = os.environ["PROJECT_NAME"]
ENVIRONMENT = os.environ["ENVIRONMENT"]
APP_TABLE_NAME = os.environ["APP_TABLE_NAME"]
ENTITY_TYPE = os.environ["ENTITY_TYPE"]
FUNCTION_NAME = os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "unknown")
GSI1_NAME = "GSI1"

logger = Logger(service=f"saas-{ENTITY_TYPE}")
tracer = Tracer(service=f"saas-{ENTITY_TYPE}")
metrics = Metrics(namespace=f"{PROJECT_NAME}/{ENVIRONMENT}", service=f"saas-{ENTITY_TYPE}")


def _iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _list(event: dict[str, Any]) -> dict[str, Any]:
    tid = get_tenant_id(event)
    ddb = get_tenant_client(event)
    resp = ddb.query(
        TableName=APP_TABLE_NAME,
        IndexName=GSI1_NAME,
        KeyConditionExpression="GSI1PK = :pk",
        ExpressionAttributeValues={":pk": {"S": gsi1_pk(tid, ENTITY_TYPE)}},
        ScanIndexForward=False,
        Limit=int((event.get("queryStringParameters") or {}).get("limit") or 50),
    )
    items = [_unmarshal(i) for i in resp.get("Items", [])]
    return response(200, {"items": items, "count": len(items)})


def _create(event: dict[str, Any]) -> dict[str, Any]:
    tid = get_tenant_id(event)
    body = parse_body(event)
    if not isinstance(body, dict) or not body:
        raise AuthError("body must be a non-empty JSON object")

    eid = str(uuid.uuid4())
    now = _iso_now()
    ddb = get_tenant_client(event)

    item = {
        "PK": {"S": tenant_pk(event)},
        "SK": {"S": entity_sk(ENTITY_TYPE, eid)},
        "GSI1PK": {"S": gsi1_pk(tid, ENTITY_TYPE)},
        "GSI1SK": {"S": now},
        "id": {"S": eid},
        "entity_type": {"S": ENTITY_TYPE},
        "created_at": {"S": now},
        "updated_at": {"S": now},
    }
    for k, v in body.items():
        if k in {"PK", "SK", "GSI1PK", "GSI1SK", "id", "tenant_id"}:
            continue  # reject any attempt to override keys / tenant_id
        item[k] = _marshal_value(v)

    ddb.put_item(
        TableName=APP_TABLE_NAME,
        Item=item,
        ConditionExpression="attribute_not_exists(PK)",
    )
    return response(201, _unmarshal(item))


def _read(event: dict[str, Any], entity_id: str) -> dict[str, Any]:
    ddb = get_tenant_client(event)
    resp = ddb.get_item(
        TableName=APP_TABLE_NAME,
        Key={"PK": {"S": tenant_pk(event)}, "SK": {"S": entity_sk(ENTITY_TYPE, entity_id)}},
        ConsistentRead=True,
    )
    item = resp.get("Item")
    if not item:
        return error(404, "not_found", f"{ENTITY_TYPE}/{entity_id} not found")
    return response(200, _unmarshal(item))


def _update(event: dict[str, Any], entity_id: str) -> dict[str, Any]:
    body = parse_body(event)
    if not isinstance(body, dict) or not body:
        raise AuthError("body must be a non-empty JSON object")

    set_parts: list[str] = ["#updated_at = :updated_at"]
    expr_names: dict[str, str] = {"#updated_at": "updated_at"}
    expr_vals: dict[str, Any] = {":updated_at": {"S": _iso_now()}}

    i = 0
    for k, v in body.items():
        if k in {"PK", "SK", "GSI1PK", "GSI1SK", "id", "tenant_id", "created_at"}:
            continue
        nk = f"#a{i}"
        nv = f":a{i}"
        expr_names[nk] = k
        expr_vals[nv] = _marshal_value(v)
        set_parts.append(f"{nk} = {nv}")
        i += 1

    ddb = get_tenant_client(event)
    try:
        resp = ddb.update_item(
            TableName=APP_TABLE_NAME,
            Key={"PK": {"S": tenant_pk(event)}, "SK": {"S": entity_sk(ENTITY_TYPE, entity_id)}},
            UpdateExpression="SET " + ", ".join(set_parts),
            ExpressionAttributeNames=expr_names,
            ExpressionAttributeValues=expr_vals,
            ConditionExpression="attribute_exists(PK)",
            ReturnValues="ALL_NEW",
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return error(404, "not_found", f"{ENTITY_TYPE}/{entity_id} not found")
        raise
    return response(200, _unmarshal(resp.get("Attributes") or {}))


def _delete(event: dict[str, Any], entity_id: str) -> dict[str, Any]:
    ddb = get_tenant_client(event)
    try:
        ddb.delete_item(
            TableName=APP_TABLE_NAME,
            Key={"PK": {"S": tenant_pk(event)}, "SK": {"S": entity_sk(ENTITY_TYPE, entity_id)}},
            ConditionExpression="attribute_exists(PK)",
        )
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return error(404, "not_found", f"{ENTITY_TYPE}/{entity_id} not found")
        raise
    return response(204, None)


# ---------------------------------------------------------------------------
# Marshalling helpers (low-level client uses {"S": ...} format)
# ---------------------------------------------------------------------------
def _marshal_value(v: Any) -> dict[str, Any]:
    if isinstance(v, bool):
        return {"BOOL": v}
    if isinstance(v, (int, float)):
        return {"N": str(v)}
    if v is None:
        return {"NULL": True}
    if isinstance(v, list):
        return {"L": [_marshal_value(x) for x in v]}
    if isinstance(v, dict):
        return {"M": {k: _marshal_value(x) for k, x in v.items()}}
    return {"S": str(v)}


def _unmarshal_value(v: dict[str, Any]) -> Any:
    if "S" in v:
        return v["S"]
    if "N" in v:
        n = v["N"]
        return int(n) if n.isdigit() or (n.startswith("-") and n[1:].isdigit()) else float(n)
    if "BOOL" in v:
        return v["BOOL"]
    if "NULL" in v:
        return None
    if "L" in v:
        return [_unmarshal_value(x) for x in v["L"]]
    if "M" in v:
        return {k: _unmarshal_value(x) for k, x in v["M"].items()}
    return next(iter(v.values()))


def _unmarshal(item: dict[str, Any]) -> dict[str, Any]:
    out = {k: _unmarshal_value(v) for k, v in item.items()}
    # Strip internal keys from the API response.
    for hidden in ("PK", "SK", "GSI1PK", "GSI1SK"):
        out.pop(hidden, None)
    return out


@metrics.log_metrics(capture_cold_start_metric=True)
@tracer.capture_lambda_handler
@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    bind_tenant_keys(logger, event)
    method = (event.get("httpMethod") or "").upper()
    path_params = event.get("pathParameters") or {}
    entity_id = path_params.get("id")
    route = f"/{ENTITY_TYPE}" + ("/{id}" if entity_id else "")

    tracer.put_annotation(key="tenant_id", value=get_tenant_id(event))
    tracer.put_annotation(key="entity_type", value=ENTITY_TYPE)

    try:
        if method == "GET" and not entity_id:
            resp = _list(event)
        elif method == "POST" and not entity_id:
            resp = _create(event)
        elif method == "GET" and entity_id:
            resp = _read(event, entity_id)
        elif method == "PATCH" and entity_id:
            resp = _update(event, entity_id)
        elif method == "DELETE" and entity_id:
            resp = _delete(event, entity_id)
        else:
            resp = error(405, "method_not_allowed", f"{method} {route}")
    except AuthError as exc:
        resp = error(400, "bad_request", str(exc))
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "AccessDeniedException":
            # Layer 2 isolation triggered — log loudly, this is either a bug or an attack.
            logger.error("LAYER-2 ISOLATION TRIPPED", extra={"aws_error_code": code})
            metrics.add_metric(name="Layer2Denied", unit=MetricUnit.Count, value=1)
            resp = error(403, "forbidden", "operation rejected by tenant isolation policy")
        else:
            logger.exception("dynamodb error")
            resp = error(500, "ddb_error", code or "dynamodb failure")
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

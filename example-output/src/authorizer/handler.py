"""Lambda authorizer: validate Cognito JWT, mint tenant-scoped STS credentials.

Flow per invocation:
    1. Extract token from the API Gateway TOKEN authorizer event
       (event["authorizationToken"]; "Bearer <jwt>" or raw JWT).
    2. Validate against Cognito JWKS (signature, exp, iss, client_id, token_use).
       JWKS is fetched once per cold-start container and refreshed every 1 h.
    3. Read custom:tenant_id + custom:role from the claims (these are written
       into the access token because the app client lists them in read_attributes).
    4. Call sts:AssumeRole on the TenantAccessRole with an inline session policy
       restricting DynamoDB to ``LeadingKeys = ["TENANT#<tenant_id>"]``.
       Per-tenant credential reuse: cache the AssumeRole result keyed by
       (tenant_id, role) with TTL ~= STS DurationSeconds * 2/3.
    5. Return an API Gateway authorizer response: principalId, an IAM policy
       allowing invoke on the entire API stage, and a context map carrying
       tenant_id, role, user_id, user_email, and the STS credentials.

Defense in depth:
    The API Gateway authorizer result is cached for ``authorizer_result_ttl``
    seconds, so the same JWT does not trigger an STS call on every request.
    To avoid the API Gateway cache outliving the STS credentials, we set
    ``STS_DURATION_SECONDS`` >= 900 and the result TTL <= ``STS_DURATION_SECONDS
    - 60`` (envs/dev defaults: STS=900s, result_ttl=300s).
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from typing import Any

import boto3
import requests
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from botocore.config import Config
from jose import jwk, jwt
from jose.utils import base64url_decode

# ---------------------------------------------------------------------------
# Configuration (immutable per cold start)
# ---------------------------------------------------------------------------
PROJECT_NAME = os.environ["PROJECT_NAME"]
ENVIRONMENT = os.environ["ENVIRONMENT"]
AWS_REGION = os.environ.get("AWS_REGION_NAME") or os.environ.get("AWS_REGION") or "us-east-1"
USER_POOL_ID = os.environ["USER_POOL_ID"]
USER_POOL_CLIENT_ID = os.environ["USER_POOL_CLIENT_ID"]
TENANT_ACCESS_ROLE_ARN = os.environ["TENANT_ACCESS_ROLE_ARN"]
APP_TABLE_ARN = os.environ["APP_TABLE_ARN"]
STS_DURATION_SECONDS = int(os.environ.get("STS_DURATION_SECONDS", "900"))

# Accept ID tokens by default (they carry custom attributes out-of-the-box).
# Set ACCEPTED_TOKEN_USES=access if you have wired a Pre-Token-Generation V2
# trigger that injects custom:tenant_id into access tokens.
ACCEPTED_TOKEN_USES = set(
    (os.environ.get("ACCEPTED_TOKEN_USES") or "id,access").split(",")
)

JWKS_URL = f"https://cognito-idp.{AWS_REGION}.amazonaws.com/{USER_POOL_ID}/.well-known/jwks.json"
EXPECTED_ISSUER = f"https://cognito-idp.{AWS_REGION}.amazonaws.com/{USER_POOL_ID}"

logger = Logger(service="saas-authorizer")
tracer = Tracer(service="saas-authorizer")
metrics = Metrics(namespace=f"{PROJECT_NAME}/{ENVIRONMENT}", service="saas-authorizer")

_boto_config = Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=2, read_timeout=5)
_sts = boto3.client("sts", config=_boto_config, region_name=AWS_REGION)

# ---------------------------------------------------------------------------
# JWKS cache (process-local, 1h TTL).
# ---------------------------------------------------------------------------
_JWKS_CACHE: dict[str, Any] = {"fetched_at": 0.0, "keys": {}}
_JWKS_TTL_SECONDS = 3600

# Tenant-credential cache: {(tenant_id, role): {"creds": {...}, "expires_at": ts}}
_STS_CACHE: dict[tuple[str, str], dict[str, Any]] = {}
_STS_CACHE_TTL_SECONDS = max(60, int(STS_DURATION_SECONDS * 2 / 3))


class AuthDenied(Exception):
    """Raised to short-circuit into a denied response with a 401-style log."""


def _fetch_jwks() -> dict[str, Any]:
    now = time.time()
    if _JWKS_CACHE["keys"] and (now - _JWKS_CACHE["fetched_at"]) < _JWKS_TTL_SECONDS:
        return _JWKS_CACHE["keys"]
    logger.info("fetching Cognito JWKS", extra={"url": JWKS_URL})
    resp = requests.get(JWKS_URL, timeout=3)
    resp.raise_for_status()
    raw = resp.json()
    keys = {k["kid"]: k for k in raw.get("keys", [])}
    if not keys:
        raise AuthDenied("empty JWKS response from Cognito")
    _JWKS_CACHE["fetched_at"] = now
    _JWKS_CACHE["keys"] = keys
    return keys


def _strip_bearer(token: str) -> str:
    token = (token or "").strip()
    if not token:
        raise AuthDenied("missing token")
    if token.lower().startswith("bearer "):
        token = token[7:].strip()
    return token


def _validate_jwt(token: str) -> dict[str, Any]:
    """Validate a Cognito JWT. Returns the decoded claims dict.

    IMPORTANT — token_use:
        By default, Cognito *access* tokens do NOT carry custom attributes
        (e.g. ``custom:tenant_id``). Only *ID* tokens do. There are two
        production patterns:

          (a) Pass the ID token in the Authorization header — simpler, what
              this code does by default. ID tokens carry ``aud`` and
              ``token_use == "id"``.
          (b) Use a Pre-Token-Generation Lambda V2 trigger to inject custom
              claims into the access token, then pass the access token. This
              avoids the convention that ID tokens "shouldn't" go to APIs but
              requires the extra Lambda + trigger plumbing. Set ACCEPT_TOKEN_USE
              to ``access`` and add the trigger before flipping to this mode.

        Cognito access tokens carry ``client_id`` (not ``aud``).
    """
    headers = jwt.get_unverified_headers(token)
    kid = headers.get("kid")
    if not kid:
        raise AuthDenied("token header missing kid")

    keys = _fetch_jwks()
    key = keys.get(kid)
    if not key:
        # Possible key rotation — refresh once.
        _JWKS_CACHE["fetched_at"] = 0
        keys = _fetch_jwks()
        key = keys.get(kid)
    if not key:
        raise AuthDenied(f"no JWKS key matches kid={kid}")

    # Verify signature manually so jose doesn't complain about audience for
    # access tokens (which use client_id, not aud).
    message, signature_b64 = token.rsplit(".", 1)
    decoded_sig = base64url_decode(signature_b64.encode("utf-8"))
    public_key = jwk.construct(key)
    if not public_key.verify(message.encode("utf-8"), decoded_sig):
        raise AuthDenied("signature verification failed")

    claims = jwt.get_unverified_claims(token)

    # exp
    now = int(time.time())
    if int(claims.get("exp", 0)) < now:
        raise AuthDenied("token expired")

    # iss
    if claims.get("iss") != EXPECTED_ISSUER:
        raise AuthDenied(f"unexpected issuer: {claims.get('iss')}")

    token_use = claims.get("token_use")
    if token_use not in ACCEPTED_TOKEN_USES:
        raise AuthDenied(f"token_use {token_use!r} not in accepted set {sorted(ACCEPTED_TOKEN_USES)}")

    # ID tokens carry 'aud'; access tokens carry 'client_id'. Validate whichever
    # is present against the configured app client.
    if token_use == "id":
        if claims.get("aud") != USER_POOL_CLIENT_ID:
            raise AuthDenied(f"aud mismatch: {claims.get('aud')}")
    else:  # access
        if claims.get("client_id") != USER_POOL_CLIENT_ID:
            raise AuthDenied(f"client_id mismatch: {claims.get('client_id')}")

    return claims


def _assume_tenant_role(tenant_id: str, role: str, user_id: str) -> dict[str, str]:
    cache_key = (tenant_id, role)
    cached = _STS_CACHE.get(cache_key)
    now = time.time()
    if cached and cached["expires_at"] > now:
        return cached["creds"]

    session_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "TenantScopedDynamoDB",
                "Effect": "Allow",
                "Action": [
                    "dynamodb:GetItem",
                    "dynamodb:PutItem",
                    "dynamodb:UpdateItem",
                    "dynamodb:DeleteItem",
                    "dynamodb:Query",
                    "dynamodb:BatchGetItem",
                    "dynamodb:BatchWriteItem",
                    "dynamodb:TransactWriteItems",
                    "dynamodb:TransactGetItems",
                    "dynamodb:ConditionCheckItem",
                ],
                "Resource": [
                    APP_TABLE_ARN,
                    f"{APP_TABLE_ARN}/index/*",
                ],
                "Condition": {
                    "ForAllValues:StringLike": {
                        "dynamodb:LeadingKeys": [
                            f"TENANT#{tenant_id}",
                            f"TENANT#{tenant_id}#*",
                        ]
                    }
                },
            }
        ],
    }

    # Session name must be 2-64 chars, [\w+=,.@-]+. Hash the user_id to stay safe.
    session_name = "saas-" + hashlib.sha1(f"{tenant_id}:{user_id}".encode()).hexdigest()[:24]

    resp = _sts.assume_role(
        RoleArn=TENANT_ACCESS_ROLE_ARN,
        RoleSessionName=session_name,
        DurationSeconds=STS_DURATION_SECONDS,
        Policy=json.dumps(session_policy, separators=(",", ":")),
        Tags=[
            {"Key": "tenant_id", "Value": tenant_id},
            {"Key": "role", "Value": role},
        ],
    )
    creds = resp["Credentials"]
    out = {
        "access_key_id": creds["AccessKeyId"],
        "secret_access_key": creds["SecretAccessKey"],
        "session_token": creds["SessionToken"],
        "expiration": creds["Expiration"].isoformat(),
    }
    _STS_CACHE[cache_key] = {"creds": out, "expires_at": now + _STS_CACHE_TTL_SECONDS}
    return out


def _allow_policy(principal_id: str, method_arn: str, context: dict[str, Any]) -> dict[str, Any]:
    # Allow the entire stage so the cached authorizer result works across
    # routes for this token. ARN shape:
    #   arn:aws:execute-api:REGION:ACCT:API/STAGE/METHOD/RESOURCE
    parts = method_arn.split(":", 5)
    api_part = parts[5] if len(parts) == 6 else method_arn
    api_id, stage, _method, _path = api_part.split("/", 3)
    stage_arn = ":".join(parts[:5]) + f":{api_id}/{stage}/*/*"
    return {
        "principalId": principal_id,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Action": "execute-api:Invoke",
                    "Effect": "Allow",
                    "Resource": stage_arn,
                }
            ],
        },
        "context": context,
    }


def _deny_policy(principal_id: str, method_arn: str, reason: str) -> dict[str, Any]:
    return {
        "principalId": principal_id,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Action": "execute-api:Invoke",
                    "Effect": "Deny",
                    "Resource": method_arn,
                }
            ],
        },
        "context": {"reason": reason},
    }


@metrics.log_metrics(capture_cold_start_metric=True)
@tracer.capture_lambda_handler
@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    method_arn = event.get("methodArn") or "*"
    raw_token = event.get("authorizationToken") or ""
    # Never log the raw token; only a short non-reversible fingerprint.
    token_fp = hashlib.sha256(raw_token.encode()).hexdigest()[:12] if raw_token else "none"
    logger.append_keys(token_fp=token_fp)

    try:
        token = _strip_bearer(raw_token)
        claims = _validate_jwt(token)
    except AuthDenied as exc:
        logger.warning("auth denied", extra={"reason": str(exc)})
        metrics.add_metric(name="AuthorizerDeny", unit=MetricUnit.Count, value=1)
        # Returning "Unauthorized" is the API Gateway-documented way to return 401.
        raise Exception("Unauthorized") from exc  # noqa: TRY002
    except Exception as exc:  # bug / network / etc.
        logger.exception("auth error")
        metrics.add_metric(name="AuthorizerError", unit=MetricUnit.Count, value=1)
        raise Exception("Unauthorized") from exc  # noqa: TRY002

    tenant_id = claims.get("custom:tenant_id")
    role = claims.get("custom:role") or "member"
    user_id = claims.get("sub") or ""
    user_email = claims.get("email") or ""

    if not tenant_id or not user_id:
        logger.warning("missing required claims", extra={"have_tenant": bool(tenant_id), "have_sub": bool(user_id)})
        metrics.add_metric(name="AuthorizerDeny", unit=MetricUnit.Count, value=1)
        return _deny_policy(user_id or "anonymous", method_arn, "missing tenant_id/sub")

    logger.append_keys(tenant_id=tenant_id, user_id=user_id, role=role)

    try:
        creds = _assume_tenant_role(tenant_id, role, user_id)
    except Exception:
        logger.exception("AssumeRole failed")
        metrics.add_metric(name="AuthorizerError", unit=MetricUnit.Count, value=1)
        raise Exception("Unauthorized")  # noqa: TRY002

    ctx = {
        "tenant_id": tenant_id,
        "role": role,
        "user_id": user_id,
        "user_email": user_email,
        "access_key_id": creds["access_key_id"],
        "secret_access_key": creds["secret_access_key"],
        "session_token": creds["session_token"],
        "credentials_expiration_iso": creds["expiration"],
    }

    logger.info("auth allow")
    metrics.add_metric(name="AuthorizerAllow", unit=MetricUnit.Count, value=1)
    return _allow_policy(user_id, method_arn, ctx)

"""Helpers for working with the authorizer-supplied request context.

Every business Lambda goes through the same Lambda authorizer, which puts the
following into ``event["requestContext"]["authorizer"]``:

    tenant_id          — the immutable tenant ID from the JWT's custom:tenant_id
    role               — admin | member
    user_id            — Cognito sub
    user_email         — email claim
    access_key_id      — temporary STS credentials, scoped to this tenant
    secret_access_key  —          ''
    session_token      —          ''
    credentials_expiration_iso — ISO8601 expiry

Business code uses these helpers; it MUST NOT pull tenant_id from the request
body or path — those are untrusted.
"""

from __future__ import annotations

import functools
import json
from typing import Any, Callable


class AuthError(Exception):
    """Raised when the authorizer context is missing or malformed."""


def _authorizer_ctx(event: dict[str, Any]) -> dict[str, Any]:
    ctx = (event.get("requestContext") or {}).get("authorizer") or {}
    if not ctx:
        raise AuthError("missing authorizer context")
    return ctx


def get_tenant_id(event: dict[str, Any]) -> str:
    """Return the tenant_id placed in the request context by the authorizer.

    NEVER read tenant_id from the request body / path / query string. Doing so
    re-introduces the cross-tenant bug class the two-layer isolation was
    designed to prevent.
    """
    ctx = _authorizer_ctx(event)
    tid = ctx.get("tenant_id")
    if not tid:
        raise AuthError("tenant_id absent from authorizer context")
    return tid


def get_role(event: dict[str, Any]) -> str:
    ctx = _authorizer_ctx(event)
    return ctx.get("role") or "member"


def get_user_id(event: dict[str, Any]) -> str:
    ctx = _authorizer_ctx(event)
    uid = ctx.get("user_id")
    if not uid:
        raise AuthError("user_id absent from authorizer context")
    return uid


def get_user_email(event: dict[str, Any]) -> str:
    ctx = _authorizer_ctx(event)
    return ctx.get("user_email") or ""


def get_tenant_credentials(event: dict[str, Any]) -> dict[str, str]:
    """Pull STS credentials out of the authorizer context.

    These are temporary and scoped via session policy to the caller's tenant.
    """
    ctx = _authorizer_ctx(event)
    creds = {
        "AccessKeyId": ctx.get("access_key_id"),
        "SecretAccessKey": ctx.get("secret_access_key"),
        "SessionToken": ctx.get("session_token"),
    }
    if not all(creds.values()):
        raise AuthError("tenant credentials absent from authorizer context")
    return creds


def response(status: int, body: dict[str, Any] | list[Any] | None) -> dict[str, Any]:
    """API Gateway proxy-integration response."""
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
        },
        "body": "" if body is None else json.dumps(body, separators=(",", ":"), default=str),
    }


def error(status: int, code: str, message: str) -> dict[str, Any]:
    return response(status, {"error": {"code": code, "message": message}})


def parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body") or ""
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise AuthError(f"invalid JSON body: {exc}") from exc
    if not isinstance(parsed, dict):
        raise AuthError("request body must be a JSON object")
    return parsed


def require_role(*allowed_roles: str) -> Callable:
    """Decorator: return 403 unless the caller's role is in allowed_roles."""

    def wrapper(handler: Callable) -> Callable:
        @functools.wraps(handler)
        def inner(event: dict[str, Any], context: Any):
            role = get_role(event)
            if role not in allowed_roles:
                return error(
                    403,
                    "forbidden",
                    f"role '{role}' is not allowed; required one of {sorted(allowed_roles)}",
                )
            return handler(event, context)

        return inner

    return wrapper

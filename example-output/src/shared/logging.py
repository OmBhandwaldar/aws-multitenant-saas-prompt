"""Structured logger that auto-injects tenant_id and user_id from the event.

Usage:
    from shared.logging import build_logger
    logger = build_logger("my-service")

    @logger.inject_lambda_context(...)
    def lambda_handler(event, context):
        bind_tenant_keys(logger, event)
        logger.info("processing", extra={"foo": "bar"})
"""

from __future__ import annotations

from typing import Any

from aws_lambda_powertools import Logger


def build_logger(service: str) -> Logger:
    return Logger(service=service)


def bind_tenant_keys(logger: Logger, event: dict[str, Any]) -> None:
    """Attach tenant_id / user_id / role to every subsequent log line.

    Silently no-ops if the authorizer context is missing (e.g. on the public
    tenant_signup route).
    """
    ctx = (event.get("requestContext") or {}).get("authorizer") or {}
    keys: dict[str, Any] = {}
    for k in ("tenant_id", "user_id", "role"):
        v = ctx.get(k)
        if v:
            keys[k] = v
    if keys:
        logger.append_keys(**keys)

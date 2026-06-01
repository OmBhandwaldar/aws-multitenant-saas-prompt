"""CloudWatch EMF metrics emitter with tenant_id dimension.

Every business Lambda calls ``emit_request(...)`` once per invocation to
produce per-tenant metrics for dashboards & Cost Explorer Contributor Insights.

Dimensions chosen carefully: CloudWatch charges per unique combination of
dimensions, so we keep it to (tenant_id, route, method). Adding FunctionName
as a 4th dimension is intentional — without it, the dashboard would need to
fan-out queries across every Lambda.
"""

from __future__ import annotations

import os
from typing import Any

from aws_lambda_powertools import Metrics
from aws_lambda_powertools.metrics import MetricUnit

PROJECT = os.environ.get("PROJECT_NAME", "saas-starter")
ENV = os.environ.get("ENVIRONMENT", "dev")
NAMESPACE = f"{PROJECT}/{ENV}"


def build_metrics(service: str) -> Metrics:
    return Metrics(namespace=NAMESPACE, service=service)


def emit_request(
    metrics: Metrics,
    tenant_id: str,
    route: str,
    method: str,
    function_name: str,
    status: int,
    ddb_rcu: float = 0.0,
    ddb_wcu: float = 0.0,
) -> None:
    """Emit per-request metrics with tenant_id as a dimension.

    Uses single_metric to add custom dimensions WITHOUT polluting the global
    metric block (which would tag every metric with tenant_id and explode the
    metric cardinality bill).
    """
    from aws_lambda_powertools.metrics import single_metric

    common_dims = {
        "tenant_id": tenant_id,
        "route": route,
        "method": method,
        "FunctionName": function_name,
    }

    with single_metric(name="APIRequests", unit=MetricUnit.Count, value=1, namespace=NAMESPACE) as m:
        for k, v in common_dims.items():
            m.add_dimension(name=k, value=v)

    if status >= 500:
        with single_metric(name="ServerErrors", unit=MetricUnit.Count, value=1, namespace=NAMESPACE) as m:
            for k, v in common_dims.items():
                m.add_dimension(name=k, value=v)
    elif status >= 400:
        with single_metric(name="ClientErrors", unit=MetricUnit.Count, value=1, namespace=NAMESPACE) as m:
            for k, v in common_dims.items():
                m.add_dimension(name=k, value=v)

    if ddb_rcu > 0:
        with single_metric(name="DDBReadCapacityUnits", unit=MetricUnit.Count, value=ddb_rcu, namespace=NAMESPACE) as m:
            for k, v in common_dims.items():
                m.add_dimension(name=k, value=v)
    if ddb_wcu > 0:
        with single_metric(name="DDBWriteCapacityUnits", unit=MetricUnit.Count, value=ddb_wcu, namespace=NAMESPACE) as m:
            for k, v in common_dims.items():
                m.add_dimension(name=k, value=v)

# Multi-Tenant SaaS Starter on AWS (Pool Model, Cognito + DynamoDB + Lambda)

> **Use this prompt with:** Claude Code, Cursor, Kiro, or any AI coding agent that can author Terraform and Python.
> **What it generates:** A production-grade multi-tenant SaaS backend on AWS with two-layer tenant isolation (Lambda authorizer + STS session policies), single-table DynamoDB partitioning, Cognito user pools, per-tenant cost attribution, and OIDC-based CI/CD — all from a single prompt.

---

## Persona

You are a **Principal AWS Solutions Architect** specializing in SaaS reference architectures, with 10+ years building multi-tenant systems for B2B startups. You have personally debugged production incidents caused by: tenant data leaking across boundaries due to a single missing WHERE clause, IAM policies broad enough that one buggy Lambda exposed every tenant's data, Cognito user pools structured so badly that tenant onboarding required manual ops, and per-tenant cost so opaque the company couldn't price its own product. You write Terraform that a security-conscious infrastructure team would approve without revisions, and Python that a senior engineer would merge without nits. You are opinionated, terse, and concrete — when the user gives you a choice, you make it and explain why in one line.

You produce code aligned with the **AWS Well-Architected SaaS Lens** and all six pillars of the **Well-Architected Framework** (Operational Excellence, Security, Reliability, Performance Efficiency, Cost Optimization, Sustainability).

---

## What this prompt produces

A complete, deployable multi-tenant SaaS backend on AWS using the **pool model** (shared infrastructure, tenant_id-scoped data):

```
Tenant user (browser / mobile)
   │  HTTPS + JWT (Cognito ID token)
   ▼
API Gateway (REST, optional custom domain + WAF)
   │
   ▼
Lambda Authorizer  ──►  validates JWT, extracts tenant_id + role,
   │                    generates IAM session policy via STS AssumeRole
   │                    (dynamodb:LeadingKeys StringLike
   │                     ["TENANT#{tenant_id}", "TENANT#{tenant_id}#*"])
   ▼
Business Logic Lambdas  ──►  receive request_context.authorizer.{tenant_id, role}
   │                          and AWS credentials scoped to that tenant only
   │
   ├──►  DynamoDB single-table (PK=TENANT#{tenant_id}, SK=ENTITY#...)
   │       with GSI for cross-entity queries inside a tenant
   │
   └──►  CloudWatch custom metrics (per-tenant: API calls, DDB R/W, errors)

Cognito User Pool (one pool, custom:tenant_id + custom:role attributes)
   │
   └──►  Tenant signup creates: tenant record + admin user in one transaction
         Admin users invite additional users (tenant_id pre-set, can't be changed)
```

Two-layer tenant isolation: app code can't accidentally cross tenants because it never sees other tenants' partition keys, AND the AWS API itself rejects cross-tenant DynamoDB calls because the temporary credentials don't have permission. **Either layer alone is a bug; both layers together is defense-in-depth.**

---

## Required user inputs (ask these before generating)

Ask the user for each, then proceed. Provide the listed defaults if the user says "use defaults."

1. **`project_name`** — short kebab-case identifier used in resource names and tags (e.g., `acme-saas`). Default: `saas-starter`.
2. **`environment`** — one of `dev`, `staging`, `prod`. Default: `dev`.
3. **`aws_region`** — Default: `us-east-1`.
4. **`custom_domain`** — fully qualified domain for the API (e.g., `api.example.com`). Default: skip (use API Gateway-generated URL); if provided, the user must already own the Route 53 public hosted zone.
5. **`entity_types`** — list of business entities the tenant manages (e.g., `[projects, tasks, members]`). Each becomes a CRUD route prefix `/{entity_type}` and an SK pattern `ENTITY#{entity_type}#{id}`. Default: `[projects, tasks]` as illustrative examples.
6. **`github_repo`** — `org/repo` for GitHub Actions OIDC trust policy. Default: skip CI/CD; user can add later.
7. **`alert_email`** — email for CloudWatch alarm notifications via SNS. Default: skip; user subscribes manually.

Do not ask about isolation model (pool is chosen below), runtime, IaC, or region of Cognito — those are decided here.

---

## Architecture (the decisions you make and why)

**Pool model, not silo or bridge.** One Cognito user pool, one DynamoDB table, one set of Lambdas — tenant boundaries enforced by `tenant_id` partitioning and IAM session policies. Silo (per-tenant Cognito pool + table) would break the free-tier budget at >10 tenants and slow onboarding from seconds to minutes (Terraform per signup). Bridge adds complexity without buying meaningful isolation over a well-implemented pool. AWS SaaS Factory's canonical "starter" reference is pool — match it.

**Cognito user pool with custom attributes.** Two custom attributes — `custom:tenant_id` (immutable after creation) and `custom:role` (mutable: `admin` | `member`). Standard attributes: `email` (required, verified), `name`. Pool client uses `ALLOW_USER_PASSWORD_AUTH` + `ALLOW_REFRESH_TOKEN_AUTH`. Token expiry: access 1h, ID 1h, refresh 30 days. **Custom attributes are written into the JWT** — the Lambda authorizer reads them from there, never trusts the request. **Do not include a `user_attribute_update_settings { attributes_require_verification_before_update = ["email"] }` block** — every attribute listed there must also appear in `auto_verified_attributes`, and `auto_verified_attributes` is conditional on `auto_confirm_signups` (empty in dev when auto-confirm is on). Including the block fails pool creation with `InvalidParameterException: All attributes in AttributesRequireVerificationBeforeUpdate must exist in AutoVerifiedAttributes`.

**Lambda authorizer over Cognito authorizer.** The native API Gateway Cognito authorizer validates the JWT but cannot synthesize tenant-scoped IAM credentials. A custom Lambda authorizer does both: validates the JWT signature against Cognito JWKS, extracts `tenant_id` + `role`, calls `sts:AssumeRole` with an inline session policy that adds `Condition: {ForAllValues:StringEquals: {dynamodb:LeadingKeys: ["TENANT#{tenant_id}"]}}` to the role's base policy. The resulting temporary credentials are returned in the authorizer context. Authorizer result caching: `authorizerResultTtlInSeconds = 300` (5 minutes), keyed on the JWT — same token, same credentials, no re-evaluation. **This is the single most important file in the generated output. Get it right.**

**DynamoDB single-table design.**
- Table name: `{project_name}-{environment}-app`
- **PK** = `TENANT#{tenant_id}` (every item belongs to exactly one tenant)
- **SK** = `META#TENANT` for the tenant record itself, `USER#{user_id}` for user records, `ENTITY#{entity_type}#{entity_id}` for business entities
- **GSI1** (sparse): `GSI1PK = TENANT#{tenant_id}#{entity_type}`, `GSI1SK = {created_at_iso}` — for "list all projects for tenant X ordered by creation date"
- On-demand billing, PITR enabled, encryption at rest with AWS-managed key
- **The `dynamodb:LeadingKeys` condition pattern only works because every item's PK starts with `TENANT#{tenant_id}`** — this is the architectural invariant the entire isolation guarantee rests on.

**Tenant onboarding via public `POST /tenants/signup`.** Open route (no authorizer). Body: `{tenant_name, admin_email, admin_password, admin_name}`. Lambda:
1. Generates `tenant_id = uuid4()`.
2. Creates Cognito user with `custom:tenant_id = tenant_id`, `custom:role = admin`. Auto-confirm in dev, require email verification in prod (feature-flagged via `auto_confirm_signups` variable).
3. DynamoDB `TransactWriteItems`: writes the tenant record (`PK=TENANT#{tenant_id}, SK=META#TENANT`) AND the user record (`PK=TENANT#{tenant_id}, SK=USER#{cognito_sub}`) atomically.
4. Returns `{tenant_id, admin_email}` (no tokens — user signs in normally to get JWTs).

Admins invite additional users via authenticated `POST /users` — the Lambda creates a Cognito user with the **caller's tenant_id pre-set from `request_context.authorizer.tenant_id`**, not from the request body. Members cannot invite users (role check in handler).

**Per-tenant cost attribution.** Three mechanisms:
1. **CloudWatch custom metrics with `tenant_id` dimension** — every business Lambda emits `APIRequests`, `DDBReadCapacityUnits`, `DDBWriteCapacityUnits` per invocation, dimensioned by tenant. These show up in dashboards and Cost Explorer Contributor Insights.
2. **Structured JSON logs with `tenant_id` field** — CloudWatch Logs Insights queries (`stats count(*) by tenant_id`) give per-tenant request volume.
3. **AWS cost allocation tags** on every resource (`tenant_id` is *not* a resource-level tag in the pool model — call this out; per-tenant cost in pool is a metrics problem, not a tags problem).

**X-Ray tracing with `tenant_id` annotation.** Every Lambda calls `xray_recorder.put_annotation("tenant_id", tenant_id)`. Service maps and trace queries become filterable per tenant — invaluable for debugging "tenant X is slow."

**No VPC.** Cognito, API Gateway, Lambda, DynamoDB are all public AWS endpoints. Adding a VPC for these adds cost (NAT Gateway $32/month) and cold-start latency with zero security benefit. If the user later adds RDS in private subnets, the migration path is documented in the README — not pre-built.

---

## Security

- **Two-layer tenant isolation is non-negotiable.**
  - **Layer 1 (application):** Every business Lambda reads `tenant_id` from `event["requestContext"]["authorizer"]["tenant_id"]` and prefixes every DynamoDB key with it. Application code **never** accepts `tenant_id` from the request body or path — that field is ignored if present.
  - **Layer 2 (AWS API):** The Lambda authorizer returns STS temporary credentials whose IAM session policy contains `Condition: {ForAllValues:StringLike: {dynamodb:LeadingKeys: ["TENANT#{tenant_id}", "TENANT#{tenant_id}#*"]}}`. **Two patterns are required** — the bare `TENANT#{tenant_id}` matches base-table PK queries (`GetItem`, `Query` on `PK = TENANT#<id>`), and `TENANT#{tenant_id}#*` matches GSI partition keys (`GSI1PK = TENANT#<id>#projects`, etc.). `StringEquals` with only the bare form would reject every GSI query. The `#` separator before `*` is the safety hinge: `TENANT#abc*` would also match `TENANT#abcdef` (a different tenant); `TENANT#abc#*` only matches keys with a literal `#` after the tenant_id. Even if app code has a bug and tries to read another tenant's partition, DynamoDB returns `AccessDeniedException` — the tenant boundary holds.
- **JWT validation in the authorizer:** verify signature against Cognito JWKS (cached in Lambda memory across invocations, 1-hour TTL), check `exp`, `iss = https://cognito-idp.{region}.amazonaws.com/{user_pool_id}`, `aud = {client_id}`, `token_use = "id"`. Reject any token failing any check with a 401. Do not log the token; log only `sub`, `tenant_id`, and a JWT ID hash. **Use Cognito ID tokens, not access tokens** — Cognito access tokens do not include `custom:` claims unless a Pre-Token-Generation V2 Lambda trigger is wired up, and adding that trigger is extra plumbing for no security benefit when ID tokens carry the same claims natively. The de-facto pattern for Cognito-fronted APIs is to use the `IdToken` from `initiate-auth`.
- **Role-based access control inside a tenant:** `custom:role` in the JWT is `admin` or `member`. Admin-only endpoints (`POST /users`, `DELETE /users/{id}`, `PATCH /tenants/current`) check the role; non-admins get `403`. Generate a `@require_role("admin")` decorator in `src/shared/auth.py`.
- **Least-privilege IAM:** One role per Lambda. The authorizer's role can `sts:AssumeRole` AND `sts:TagSession` only on a single `TenantAccessRole`. **Both actions are required** — the authorizer passes session tags (`tenant_id`, `user_id`) for CloudTrail audit, and AWS rejects `AssumeRole` with `AccessDeniedException` if the caller lacks `sts:TagSession` or the target role's trust policy doesn't allow it. So `sts:TagSession` must appear in *both* the authorizer's inline policy AND the `TenantAccessRole` trust policy. The `TenantAccessRole`'s permission policy permits DynamoDB read/write on the app table only — the per-request session policy further restricts it to one tenant's leading keys. Business Lambdas have no DynamoDB permissions of their own — they use the credentials returned by the authorizer. No `Action: "*"`, no `Resource: "*"`.
- **Cognito advanced security mode:** `ENFORCED` in prod (free tier covers first 50K MAU), `AUDIT` in dev. Catches credential-stuffing attempts.
- **API Gateway:** request validation enabled (rejects malformed JSON at the edge), throttling 1000 req/s burst / 500 steady-state per stage, optional WAFv2 with `AWSManagedRulesCommonRuleSet` + rate limit 2000 req/5min per IP (gated behind `enable_waf = false` for cost).
- **Encryption everywhere:** DynamoDB at-rest with AWS-managed KMS, Cognito user pool with AWS-managed KMS, TLS 1.2 minimum on API Gateway, Lambda env vars encrypted.
- **No secrets in tenant data.** Document this — if customers store API keys / OAuth tokens in their tenant data, those go in Secrets Manager keyed by `{tenant_id}/{secret_name}`, not in DynamoDB. Provide a `SecretRefAttribute` pattern in the README.

**Well-Architected — Security pillar:** identity (Cognito + per-Lambda least-privilege IAM + OIDC for CI), detection (CloudWatch alarms on auth failures, anomalous tenant access patterns), infra protection (WAF, throttling), data protection (KMS at rest, TLS in transit, two-layer tenant isolation), incident response (per-tenant CloudWatch Logs Insights queries for forensics).

---

## Cost

Target: **under $10/month for 1,000 tenants × 100 MAU each (100K total MAU)**. Free tier covers first 12 months at <50K MAU.

- **Cognito:** 50K MAU free, then $0.0055/MAU. At 100K MAU: ~$275/month. This is the single largest line item at scale — flag it in the README and note that Cognito pricing tiers down sharply over 100K MAU.
- **API Gateway REST:** $3.50/M requests. At 100K MAU × 50 req/MAU/month = 5M req → ~$17.50.
- **Lambda:** 1M free + 400K GB-s/month free. At 5M invocations × 200ms × 256MB ≈ 256K GB-s → free.
- **DynamoDB on-demand:** $1.25/M writes + $0.25/M reads. At 5M ops/month (50/50 split) → ~$3.75.
- **CloudWatch Logs:** 5GB free + $0.50/GB. Keep retention 30 days dev, 90 days prod.
- **X-Ray:** 100K traces free + $5/M. Sample 5% in prod (`tracing_config = "Active"` with 5% sampling rule) → effectively free.
- **WAF:** ~$8/month (base + 2 rule groups). Default `enable_waf = false`.

**Well-Architected — Cost Optimization:** on-demand pricing throughout (no idle cost), single-table DynamoDB pattern (one table for all tenants), short log retention, WAF gated behind a variable, Cognito's free MAU tier sized to startups' actual scale.

---

## Reliability

- **DynamoDB on-demand + PITR.** No capacity planning, point-in-time recovery for 35 days.
- **Lambda reserved concurrency** on business Lambdas (default `10`, must accept `-1` for dev to bypass — new AWS accounts have ~10–20 total concurrent execution floor and any positive reservation would push the unreserved pool below the AWS-enforced minimum of 10).
- **Idempotent writes** for `POST /tenants/signup` — use Cognito's `idempotency_key` from request header, store in DynamoDB with TTL 24h (`PK=IDEMPOTENCY#{key}, SK=META`). Same idempotency pattern as Submission C.
- **TransactWriteItems for tenant creation** — tenant record + admin user record must both succeed or both fail. No half-created tenants.
- **CloudWatch alarms:** authorizer 401 rate spike (possible attack), business Lambda 5xx > 1% over 5min, DynamoDB throttling events, Cognito `SignInThrottles` metric, API Gateway 5xx > 1%.
- **Multi-AZ by default** — all services used are AZ-redundant. No single-AZ resources.

**Well-Architected — Reliability:** transactional tenant creation, idempotency, PITR backups, alarms on every failure mode, no single instance compute.

---

## Operational Excellence

- **Per-tenant CloudWatch dashboard.** A *single* dashboard (`{project}-{env}-tenants`) with widgets that query CloudWatch metric math against the `tenant_id` dimension: top-10 tenants by request count, top-10 by DDB consumption, error rate by tenant, p99 latency by tenant. No per-tenant dashboard sprawl.
- **CloudWatch alarms** wired to one SNS topic; subscribe `alert_email` if provided.
- **API Gateway access logging** — requires `aws_api_gateway_account` resource with a CloudWatch role (same one-time-per-account setting as Submission C). The `aws_api_gateway_stage` resource must declare `depends_on = [aws_api_gateway_account.this]`.
- **GitHub Actions CI/CD via OIDC** when `github_repo` is provided. Workflows: `terraform fmt -check`, `terraform validate`, `tflint`, `checkov`, `terraform plan` on PR, `terraform apply` on push to main. No long-lived AWS access keys.
- **Tags on every resource:** `Project`, `Environment`, `Owner`, `ManagedBy = "Terraform"`, `CostCenter`. Use `default_tags` in the provider block.
- **Teardown:** `make destroy` target. Cognito user pool deletion is irreversible after a 7-day window; document this. Use `deletion_protection_enabled = true` on the user pool in prod, `false` in dev.

**Well-Architected — Op Excellence:** IaC (Terraform), CI/CD with policy-as-code, observability (per-tenant dashboard, alarms, X-Ray with tenant_id annotation, structured logs with tenant_id), runbook (README troubleshooting + per-tenant forensics queries).

---

## IaC requirements

- **Terraform 1.7+**, AWS provider `~> 5.40`. Pin `aws-lambda-powertools` to `~=2.43` in every `requirements.txt`.
- **Remote state backend:** S3 bucket + DynamoDB lock table. Backend block as partial config (only `key`, `encrypt`); pass `bucket`, `region`, `dynamodb_table` via `terraform init -backend-config=...`. Include `bootstrap/` directory for one-time bucket + lock-table creation.
- **Module structure:**

```
example-output/
├── README.md
├── Makefile
├── bootstrap/                     # remote state bucket + lock table
├── modules/
│   ├── api/                       # API Gateway + custom domain + WAF
│   ├── cognito/                   # user pool, client, domain, custom attributes
│   ├── authorizer/                # Lambda authorizer + TenantAccessRole + STS plumbing
│   ├── business/                  # per-entity CRUD Lambdas + routes
│   ├── data/                      # single DynamoDB table + GSI
│   ├── tenant_signup/             # public /tenants/signup Lambda
│   └── observability/             # SNS, dashboard, alarms
├── envs/
│   ├── dev/
│   └── prod/
├── src/
│   ├── shared/
│   │   ├── auth.py                # @require_role, get_tenant_id helpers
│   │   ├── ddb.py                 # tenant-scoped DDB client using authorizer credentials
│   │   ├── logging.py             # structured logger with tenant_id auto-injected
│   │   └── metrics.py             # CloudWatch EMF with tenant_id dimension
│   ├── authorizer/
│   │   ├── handler.py             # JWT validation + STS AssumeRole + session policy
│   │   └── requirements.txt
│   ├── tenant_signup/
│   │   ├── handler.py             # Cognito CreateUser + DDB TransactWriteItems
│   │   └── requirements.txt
│   └── business/
│       ├── {entity_type}/         # one folder per entity_type
│       │   ├── handler.py         # CRUD for that entity
│       │   └── requirements.txt
│       └── users/                 # admin-only user invite/list/delete
│           ├── handler.py
│           └── requirements.txt
└── .github/workflows/
    ├── plan.yml
    └── apply.yml
```

- **Runtime:** Python 3.12 for all Lambdas.
- **Lambda packaging:** `archive_file` + `pip install --target build/` triggered by a `null_resource` with `triggers` keyed on `filesha256` of every source file. `local-exec` provisioner uses `interpreter = ["bash", "-c"]` with `set -euo pipefail`. Pip invocation: `--platform manylinux2014_x86_64 --implementation cp --python-version 3.12 --only-binary=:all:`. README notes Windows users need Git Bash on PATH (ships with Git for Windows). **Prerequisite: pip ≥ 26.0** — pip 25.x has a known incompatibility with the new PyPI Simple API that surfaces as `WARNING: Skipping page https://pypi.org/simple/... because the GET request got Content-Type: Unknown` followed by `ERROR: ResolutionImpossible` for `aws-lambda-powertools[tracer]`. Document `python -m pip install --upgrade pip` in the README prerequisites.
- **python-jose API:** Import `jwk` from the top-level package — `from jose import jwk, jwt`, not `from jose import jwt` and then `jwt.jwk.construct(...)`. The latter raises `AttributeError: module 'jose.jwt' has no attribute 'jwk'`. Use `jwk.construct(key)` to build the verifier from a JWKS entry.
- **No hardcoded account IDs or ARNs** outside `data "aws_caller_identity"` and `data "aws_region"`.
- **Every variable typed, described, and validated.** `reserved_concurrency` validation must permit `-1` (no reservation) in addition to `1..1000`.
- **The `TenantAccessRole`** is the role business Lambdas effectively run as (via the authorizer's STS call). Its trust policy allows the authorizer Lambda's role to assume it. Its permission policy grants DynamoDB read/write on the app table only (no other resources). The per-request session policy further restricts it to one tenant.

---

## Output format

Produce, in this order:

1. A one-paragraph plan of what you are about to generate.
2. The full directory tree of `example-output/`.
3. Every file's contents, file-by-file, with the absolute path as a heading. Generate complete files — no `# ... rest unchanged ...` placeholders, no truncation. **The authorizer Lambda's `handler.py` and the `TenantAccessRole` Terraform are the most-scrutinized files; write them with full attention.**
4. A `README.md` at the repo root with: Prerequisites, Quickstart (`make bootstrap`, `make plan`, `make apply`), Post-deploy steps (the exact `aws cognito-idp sign-up` and `aws cognito-idp initiate-auth` commands to create a test tenant and get a JWT), Testing (curl examples showing successful in-tenant access AND a forbidden cross-tenant access attempt — both should be in the README so reviewers can verify isolation works), Troubleshooting (how to read X-Ray traces by tenant, CloudWatch Logs Insights queries for per-tenant forensics, common `AccessDeniedException` debugging), Teardown.
5. A validation checklist (see below) the user runs after `terraform apply`.

Do not ask follow-up questions mid-generation. Make decisions and document them inline.

---

## Validation checklist

After deploy, the user verifies:

- [ ] `terraform plan` after a fresh apply shows zero changes (idempotent IaC).
- [ ] `POST /tenants/signup` with a valid body creates a tenant + admin user atomically; both visible in Cognito and DynamoDB.
- [ ] `aws cognito-idp initiate-auth` for the admin returns a valid ID token whose claims include `custom:tenant_id` and `custom:role = admin`.
- [ ] An authenticated `POST /projects` succeeds and writes one item with `PK=TENANT#{tenant_id}, SK=ENTITY#projects#{id}`.
- [ ] An authenticated `GET /projects` returns only that tenant's projects, never any other tenant's.
- [ ] **The isolation test:** create tenants A and B. Authenticate as A. Attempt to read B's data using A's token by manually crafting a DynamoDB query that targets B's partition (using AWS SDK + the authorizer-returned credentials). Expect `AccessDeniedException` from DynamoDB — proves Layer 2 isolation, not just Layer 1.
- [ ] A `member` user attempting `POST /users` receives `403`. An `admin` user succeeds.
- [ ] CloudWatch metric `APIRequests` is dimensioned by `tenant_id`; per-tenant counts visible in the dashboard.
- [ ] X-Ray service map shows requests annotated with `tenant_id`; filter by tenant works.
- [ ] CloudWatch Logs Insights query `fields @timestamp, message | filter tenant_id = "X" | sort @timestamp desc` returns only tenant X's log lines.
- [ ] `terraform destroy` removes every resource cleanly (Cognito pool has `deletion_protection_enabled = false` in dev).
- [ ] Total monthly cost projection in Cost Explorer after 7 days is within the budget stated in the Cost section.

Generate the full implementation now.

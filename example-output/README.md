# Multi-Tenant SaaS Starter (pool model) — example output

Production-grade multi-tenant SaaS backend on AWS, generated from [`../prompt.md`](../prompt.md). Two-layer tenant isolation: a Lambda authorizer mints STS credentials whose session policy restricts DynamoDB to a single tenant's partition, **and** the application code never reads `tenant_id` from anywhere except the authorizer context. Either layer alone would be a security bug; both together is defense in depth.

```
Browser / mobile
   │  HTTPS + Bearer <jwt>
   ▼
API Gateway (REST, regional)
   │
   ▼
Lambda Authorizer (TOKEN)
   │  - validates JWT against Cognito JWKS
   │  - reads custom:tenant_id, custom:role from claims
   │  - sts:AssumeRole on TenantAccessRole with session policy:
   │       Condition: dynamodb:LeadingKeys = ["TENANT#<tid>"]
   │  - returns IAM policy + context{tenant_id, role, STS creds}
   ▼
Business Lambdas (per entity_type, plus /users)
   │  - read tenant_id from authorizer context ONLY
   │  - build boto3 DDB client from the STS creds in the context
   ▼
DynamoDB single-table  (PK=TENANT#<tid>, SK=ENTITY#...)
                       GSI1 (sparse): TENANT#<tid>#<type>, created_at

Cognito user pool — one pool, custom attrs tenant_id (immutable) + role
                    Tokens flow tenant_id/role to API Gateway via JWT claims.
```

---

## Prerequisites

| Tool       | Version |
|------------|---------|
| Terraform  | >= 1.7.0 |
| AWS CLI v2 | latest |
| Python     | 3.12 |
| pip        | bundled |
| make       | any GNU make |
| bash       | required by the Lambda packaging step (Git Bash works on Windows) |

Configure AWS credentials (`aws configure` or a profile). The credentials need permission to manage Lambda, API Gateway, IAM, DynamoDB, Cognito, CloudWatch, SNS, STS, and (optionally) ACM / Route53 / WAFv2.

> **CI/CD via GitHub Actions OIDC** is described in the prompt but the workflows were skipped during generation. To add later, follow the OIDC trust-policy pattern in the prompt's IaC section.

---

## Quickstart (dev)

```bash
# 0. One-time per AWS account: create the remote state bucket + lock table.
make bootstrap

# Copy the two bootstrap outputs:
#   state_bucket_name = "saas-starter-tfstate-<acct>-us-east-1"
#   lock_table_name   = "saas-starter-tfstate-lock"

# 1. Initialize the dev env.
make init ENV=dev \
  BUCKET=saas-starter-tfstate-<acct>-us-east-1 \
  TABLE=saas-starter-tfstate-lock

# 2. Plan + apply.
make plan ENV=dev
make apply ENV=dev

# 3. Print outputs (API URL, user pool, table, role ARN).
make outputs ENV=dev
```

After `make apply` succeeds, capture these outputs into shell vars — they're used in every example below:

```bash
cd envs/dev
export API=$(terraform output -raw api_base_url)
export POOL_ID=$(terraform output -raw user_pool_id)
export CLIENT_ID=$(terraform output -raw user_pool_client_id)
export REGION=us-east-1
cd ../..
```

---

## Post-deploy: create a test tenant and obtain a JWT

### Sign up tenant A

```bash
curl -sS -X POST "$API/tenants/signup" \
  -H "Content-Type: application/json" \
  -d '{
    "tenant_name": "Acme Inc",
    "admin_email": "alice@acme.example",
    "admin_password": "Sup3r$ecret-12!",
    "admin_name": "Alice Founder"
  }'
# expect 201 with {"tenant_id":"...","admin_email":"alice@acme.example","user_id":"..."}
```

Save the returned `tenant_id` as `TENANT_A`.

### Sign in to get a JWT

```bash
TOKENS_A=$(aws cognito-idp initiate-auth \
  --region $REGION \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $CLIENT_ID \
  --auth-parameters USERNAME=alice@acme.example,PASSWORD='Sup3r$ecret-12!')
export JWT_A=$(echo "$TOKENS_A" | python -c "import sys,json;print(json.load(sys.stdin)['AuthenticationResult']['IdToken'])")
echo "$JWT_A" | cut -d. -f2 | base64 -d 2>/dev/null | python -m json.tool
# claims should include "custom:tenant_id", "custom:role":"admin", "token_use":"id"
# (Cognito ID tokens carry custom attributes by default; access tokens require
# a Pre-Token-Generation V2 trigger to do the same — see the authorizer
# handler's module docstring.)
```

> If `auto_confirm_signups = false` (prod-style), the admin first needs to verify their email and reset the temporary password before `USER_PASSWORD_AUTH` succeeds.

### Sign up tenant B (for the isolation test below)

```bash
curl -sS -X POST "$API/tenants/signup" \
  -H "Content-Type: application/json" \
  -d '{
    "tenant_name": "Globex",
    "admin_email": "bob@globex.example",
    "admin_password": "Sup3r$ecret-12!",
    "admin_name": "Bob Founder"
  }'
# Save the returned tenant_id as TENANT_B.

TOKENS_B=$(aws cognito-idp initiate-auth \
  --region $REGION \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $CLIENT_ID \
  --auth-parameters USERNAME=bob@globex.example,PASSWORD='Sup3r$ecret-12!')
export JWT_B=$(echo "$TOKENS_B" | python -c "import sys,json;print(json.load(sys.stdin)['AuthenticationResult']['IdToken'])")
```

---

## Testing — in-tenant CRUD (happy path)

```bash
# Create a project in tenant A.
curl -sS -X POST "$API/projects" \
  -H "Authorization: Bearer $JWT_A" \
  -H "Content-Type: application/json" \
  -d '{"name":"Migrate to AWS","status":"open"}'
# expect 201 with {"id":"<uuid>","entity_type":"projects",...}

# List tenant A's projects.
curl -sS -X GET "$API/projects" \
  -H "Authorization: Bearer $JWT_A"
# expect {"items":[{...one project...}],"count":1}

# Now do the same from tenant B's JWT.
curl -sS -X POST "$API/projects" \
  -H "Authorization: Bearer $JWT_B" \
  -H "Content-Type: application/json" \
  -d '{"name":"Build SaaS","status":"open"}'
curl -sS -X GET "$API/projects" -H "Authorization: Bearer $JWT_B"
# expect ONLY tenant B's project, never tenant A's.
```

---

## The isolation test (this is the marquee guarantee)

This proves both layers hold.

### Layer 1 (app code) — tenant_id is read from the JWT context, not the request

A's JWT will only ever cause the business Lambda to query `PK = TENANT#<TENANT_A>`. There is no API surface that lets a caller specify a different `tenant_id` — the handlers explicitly strip `tenant_id` from the request body before forwarding to DynamoDB (see `src/business/projects/handler.py:_create`). You cannot read B's data by sending `{"tenant_id": "<TENANT_B>"}` in the body.

```bash
# Try to exploit: request body includes a forged tenant_id.
curl -sS -X POST "$API/projects" \
  -H "Authorization: Bearer $JWT_A" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"PWN\",\"tenant_id\":\"$TENANT_B\"}"
# Result: the project is created in TENANT_A's partition — the forged
# tenant_id field is silently ignored. List tenant B's data to confirm
# the forged item did NOT land there:
curl -sS -X GET "$API/projects" -H "Authorization: Bearer $JWT_B"
# expect to see only tenant B's own item, not "PWN".
```

### Layer 2 (AWS API) — STS session policy makes cross-tenant calls fail at DynamoDB

Even if a developer accidentally writes `PK = "TENANT#<other>"` in app code, the credentials returned by the authorizer cannot read that partition: DynamoDB itself rejects the call.

To prove this, extract the STS credentials that were issued for JWT_A and use them directly with the AWS CLI to target tenant B's partition. This bypasses your app code entirely.

```bash
# 1. Trigger one authenticated request to populate the authorizer cache
# and surface a fresh set of STS creds in the Lambda logs.
AUTHORIZER_FN=$(cd envs/dev && terraform output -raw authorizer_function_name)
curl -sS -X GET "$API/projects" -H "Authorization: Bearer $JWT_A" >/dev/null

# 2. Grab the STS creds from the most recent authorizer invocation log line.
# (For convenience: in dev set LOG_LEVEL=DEBUG so the creds are logged.
#  In prod they are NOT logged. Replace this with `aws sts assume-role` from
#  the authorizer's role manually if you need to repro outside dev.)
LOG_GROUP="/aws/lambda/$AUTHORIZER_FN"
# ...inspect logs and copy AccessKeyId / SecretAccessKey / SessionToken...

# 3. Now use those creds to try to query tenant B's partition.
APP_TABLE=$(cd envs/dev && terraform output -raw app_table_name)

AWS_ACCESS_KEY_ID=<from-step-2> \
AWS_SECRET_ACCESS_KEY=<from-step-2> \
AWS_SESSION_TOKEN=<from-step-2> \
aws dynamodb query \
  --region $REGION \
  --table-name $APP_TABLE \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values "{\":pk\":{\"S\":\"TENANT#$TENANT_B\"}}"
# expect: An error occurred (AccessDeniedException) when calling the Query
# operation: User: ... is not authorized to perform: dynamodb:Query on
# resource: ... because of session policy.
```

For step 2 in a hardened environment (where credentials are not logged), an easier way to reproduce Layer 2 is to call `sts:assume-role` yourself, replacing tenant A's id in the session policy with tenant B's, and observe that DynamoDB still denies queries against partitions outside the policy.

```bash
ROLE_ARN=$(cd envs/dev && terraform output -raw tenant_access_role_arn)
APP_TABLE_ARN=$(cd envs/dev && terraform output -raw app_table_arn)

# Create a session policy claiming access to TENANT_A's partition.
cat > /tmp/sp.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["dynamodb:Query","dynamodb:GetItem"],"Resource":["$APP_TABLE_ARN","$APP_TABLE_ARN/index/*"],"Condition":{"ForAllValues:StringEquals":{"dynamodb:LeadingKeys":["TENANT#$TENANT_A"]}}}]}
JSON

CREDS=$(aws sts assume-role \
  --role-arn $ROLE_ARN \
  --role-session-name layer2-test \
  --policy file:///tmp/sp.json \
  --duration-seconds 900)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | python -c "import sys,json;print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python -c "import sys,json;print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo "$CREDS" | python -c "import sys,json;print(json.load(sys.stdin)['Credentials']['SessionToken'])")

# Query tenant A's partition — succeeds.
aws dynamodb query --region $REGION --table-name $APP_TABLE \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values "{\":pk\":{\"S\":\"TENANT#$TENANT_A\"}}"

# Query tenant B's partition — fails with AccessDeniedException.
aws dynamodb query --region $REGION --table-name $APP_TABLE \
  --key-condition-expression "PK = :pk" \
  --expression-attribute-values "{\":pk\":{\"S\":\"TENANT#$TENANT_B\"}}" \
  || echo "Layer 2 isolation verified: AccessDeniedException as expected."

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

If this last command succeeds (returns items), Layer 2 is broken — DO NOT deploy this configuration.

---

## Role-based access control inside a tenant

```bash
# Invite a member as the admin — succeeds.
curl -sS -X POST "$API/users" \
  -H "Authorization: Bearer $JWT_A" \
  -H "Content-Type: application/json" \
  -d '{"email":"member@acme.example","name":"Mike","role":"member"}'

# Sign in as the member.
# (set NEW_PASSWORD on first sign-in if email verification is enforced.)
TOKENS_M=$(aws cognito-idp initiate-auth --region $REGION \
  --auth-flow USER_PASSWORD_AUTH --client-id $CLIENT_ID \
  --auth-parameters USERNAME=member@acme.example,PASSWORD='...')
JWT_M=$(echo "$TOKENS_M" | python -c "import sys,json;print(json.load(sys.stdin)['AuthenticationResult']['IdToken'])")

# Member can list projects.
curl -sS -X GET "$API/projects" -H "Authorization: Bearer $JWT_M"
# expect 200

# Member CANNOT invite users.
curl -sS -X POST "$API/users" \
  -H "Authorization: Bearer $JWT_M" \
  -H "Content-Type: application/json" \
  -d '{"email":"sneaky@acme.example","role":"admin"}'
# expect 403 {"error":{"code":"forbidden","message":"role 'member' is not allowed..."}}
```

---

## Troubleshooting

### "Unauthorized" on every request

The Lambda authorizer returned a deny / threw. Check CloudWatch Logs:

```
fields @timestamp, level, message, reason, token_fp
| filter @logStream like /authorizer/
| sort @timestamp desc
| limit 20
```

Common causes:
- Token expired (1h access-token lifetime — get a fresh one).
- Token is an ID token, not an access token (`token_use != "access"`).
- `client_id` claim doesn't match the deployed app client (you re-applied with a new client ID).

### `AccessDeniedException` from a business Lambda

This is intentional when the call would have crossed tenants — see the Layer 2 test above. If you see it on legitimate in-tenant calls, the most likely cause is a key in the request that does **not** start with `TENANT#<tenant_id>` (every PK must). Search the Lambda's CloudWatch Logs for the key shape:

```
fields @timestamp, message, tenant_id
| filter message like /LAYER-2 ISOLATION TRIPPED/
| sort @timestamp desc
| limit 20
```

### Per-tenant forensics

```
# Every business request, scoped to one tenant:
fields @timestamp, message, tenant_id, user_id, role
| filter tenant_id = "<TENANT_ID>"
| sort @timestamp desc
| limit 100
```

```
# Per-tenant error rate (Layer 2 trips count here):
fields @timestamp, message, tenant_id
| filter level in ["ERROR","WARNING"]
| stats count(*) by tenant_id
| sort `count(*)` desc
```

### Reading X-Ray traces by tenant

1. Console → X-Ray → Traces.
2. Filter expression: `annotation.tenant_id = "<TENANT_ID>"`.
3. The trace contains: API Gateway → Authorizer → STS:AssumeRole → Business Lambda → DynamoDB. Authorizer cache hits skip the STS span.

### `BadRequestException: CloudWatch Logs role ARN must be set...`

The API Gateway account-level CloudWatch role wasn't created before the stage tried to enable logging. The module wires `depends_on = [aws_api_gateway_account.this]` on the stage to prevent this — if you see it, run `terraform apply` again (it's idempotent).

### `Permanent password required` on first member sign-in

When `auto_confirm_signups = false`, members go through the Cognito email-verification flow on first sign-in. Use `aws cognito-idp respond-to-auth-challenge` with the `NEW_PASSWORD_REQUIRED` challenge.

---

## Costs

For ~100K MAU (1,000 tenants × 100 users):

| Service              | Monthly                       |
|----------------------|-------------------------------|
| Cognito (>50K MAU)   | ~$275 (largest line item)     |
| API Gateway REST     | ~$17.50 (5M req)              |
| Lambda               | free tier                     |
| DynamoDB on-demand   | ~$3.75 (5M ops)               |
| STS AssumeRole       | free (no per-call charge)     |
| CloudWatch Logs      | $0–$5                         |
| X-Ray (5% sampling)  | ~free                         |
| WAFv2 (if enabled)   | ~$8                           |
| **Total (no WAF)**   | **~$300/month** dominated by Cognito |

Under 50K MAU the entire stack stays inside Cognito's free tier — total monthly cost is typically under $5.

---

## Teardown

```bash
make destroy ENV=dev

# Optional: remove the remote state bucket + lock table.
cd bootstrap && terraform destroy
```

> Cognito user pool deletion is irreversible after a 7-day window — confirm the `user_pool_id` shown in the destroy plan before proceeding. Prod uses `deletion_protection_enabled = true`; disable it before destroy.

---

## Validation checklist

- [ ] `make plan ENV=dev` after a fresh apply shows **No changes** (idempotent IaC).
- [ ] `POST /tenants/signup` creates the Cognito admin user **and** the DynamoDB tenant + user records atomically (both visible).
- [ ] `aws cognito-idp initiate-auth` returns an access token whose claims include `custom:tenant_id` and `custom:role = "admin"`.
- [ ] Authenticated `POST /projects` writes one item with `PK=TENANT#<tid>, SK=ENTITY#projects#<id>`.
- [ ] Authenticated `GET /projects` returns only that tenant's projects, never any other tenant's.
- [ ] **The Layer 2 isolation test** above using `aws sts assume-role` shows `AccessDeniedException` when querying another tenant's partition. **If this step succeeds, do not deploy this configuration.**
- [ ] A `member` user attempting `POST /users` receives 403; an `admin` user succeeds.
- [ ] CloudWatch metric `APIRequests` is dimensioned by `tenant_id` and visible in the `${project}-${env}-tenants` dashboard.
- [ ] X-Ray service map shows requests annotated with `tenant_id`; the trace filter `annotation.tenant_id = "<TENANT_ID>"` works.
- [ ] CloudWatch Logs Insights query `fields @timestamp | filter tenant_id = "<TID>" | sort @timestamp desc` returns only that tenant's lines.
- [ ] `terraform destroy` removes every resource cleanly in dev (deletion protection off).
- [ ] After 7 days, Cost Explorer projection is within the budget stated above.

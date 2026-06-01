# Backend configuration is intentionally minimal here — pass the bucket /
# region / dynamodb_table via `terraform init -backend-config=` after
# running the bootstrap stack. Example:
#
#   terraform init \
#     -backend-config="bucket=saas-starter-tfstate-123456789012-us-east-1" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=saas-starter-tfstate-lock"
#
# The backend block itself is declared in main.tf.

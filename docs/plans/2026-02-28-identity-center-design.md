# Identity Center Integration Design

## Overview

Replace the `iam-personas` module with IAM Identity Center (IC) for human identity management. IC groups and permission sets replace the three human persona IAM roles. The Kafka Connect IRSA role moves to a new `service-roles` module. Lake Formation grants switch from IAM role ARN principals to IC group ARN principals via trusted identity propagation.

## Architecture

### Before

```
iam-personas/
  ├── finance-analyst IAM role  ──→ Lake Formation grant (role ARN)
  ├── data-analyst IAM role     ──→ Lake Formation grant (role ARN)
  ├── data-engineer IAM role    ──→ Lake Formation grant (role ARN) + S3 bucket policy bypass
  └── kafka-connect IRSA role   ──→ S3 bucket policy bypass
```

### After

```
identity-center/
  ├── FinanceAnalysts IC group   ──→ Lake Formation grant (group ARN)
  │   └── FinanceAnalyst permission set (Athena + Glue read + LF GetDataAccess)
  ├── DataAnalysts IC group      ──→ Lake Formation grant (group ARN)
  │   └── DataAnalyst permission set (Athena + Glue read + LF GetDataAccess)
  ├── DataEngineers IC group     ──→ Lake Formation grant (group ARN) + S3 bucket policy bypass (via SSO role wildcard)
  │   └── DataEngineer permission set (Athena + Glue CRUD + direct S3 + LF GetDataAccess)
  └── 3 demo users (one per group)

service-roles/
  └── kafka-connect IRSA role    ──→ S3 bucket policy bypass

lake-formation/ (modified)
  ├── aws_lakeformation_identity_center_configuration (NEW)
  └── LF-Tag grants → principal = arn:aws:identitystore:::group/<id>
```

## Module Details

### identity-center/ (new)

**Data sources:**
- `aws_ssoadmin_instances` — SSO instance ARN + identity store ID

**Resources:**

| Resource | Count | Purpose |
|----------|-------|---------|
| `aws_identitystore_group` | 3 | FinanceAnalysts, DataAnalysts, DataEngineers |
| `aws_ssoadmin_permission_set` | 3 | One per persona with inline IAM policies |
| `aws_ssoadmin_permission_set_inline_policy` | 3 | Athena, Glue, S3, LF policies |
| `aws_ssoadmin_account_assignment` | 3 | Group + permission set → account |
| `aws_identitystore_user` | 3 | Demo users: jane.finance, alex.analyst, sam.engineer |
| `aws_identitystore_group_membership` | 3 | Each demo user → their group |

**Variables:**
- `environment` — dev/prod
- `account_id` — AWS account ID
- `mnpi_bucket_arn` — for DataEngineer S3 policy
- `nonmnpi_bucket_arn` — for DataEngineer S3 policy
- `query_results_bucket_arn` — for all permission sets (Athena results)

**Outputs:**
- `finance_analysts_group_id` — for Lake Formation grants
- `data_analysts_group_id` — for Lake Formation grants
- `data_engineers_group_id` — for Lake Formation grants
- `data_engineer_sso_role_pattern` — ArnLike pattern for bucket policy bypass
- `sso_instance_arn` — for Lake Formation IC configuration

### Permission Set Policies

**FinanceAnalyst & DataAnalyst** (identical IAM policies — LF-Tags handle data restriction):

```json
{
  "Statement": [
    {"Sid": "AthenaQueryExecution", "Action": ["athena:StartQueryExecution", "athena:StopQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:GetWorkGroup", "athena:BatchGetQueryExecution", "athena:ListQueryExecutions"]},
    {"Sid": "GlueCatalogRead", "Action": ["glue:GetTable", "glue:GetTables", "glue:GetDatabase", "glue:GetDatabases", "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition"]},
    {"Sid": "S3QueryResultsAccess", "Resource": ["query-results-bucket/*"]},
    {"Sid": "LakeFormationDataAccess", "Action": ["lakeformation:GetDataAccess"]}
  ]
}
```

**DataEngineer** (adds direct S3 + Glue CRUD):

Same as above, plus:
- `glue:CreateTable`, `glue:UpdateTable`, `glue:DeleteTable`, `glue:CreatePartition`, etc.
- Direct S3 access to MNPI + non-MNPI buckets (GetObject, PutObject, DeleteObject)

### service-roles/ (new)

Extracted from `iam-personas`. Contains only machine identity roles.

**Resources:**
- `aws_iam_role.kafka_connect` — IRSA for Strimzi KafkaConnect pods
- `aws_iam_role_policy.kafka_connect_msk` — MSK IAM auth
- `aws_iam_role_policy.kafka_connect_s3` — S3 data lake write
- `aws_iam_role_policy.kafka_connect_glue` — Glue catalog + schema registry

**Variables:** Same as current kafka-connect inputs from iam-personas.

**Outputs:**
- `kafka_connect_role_arn`
- `kafka_connect_role_name`

### lake-formation/ (modified)

**New resources:**
- `aws_lakeformation_identity_center_configuration` — bridges LF to IC

**Changed resources:**
All `aws_lakeformation_permissions` grants switch principal from:
```hcl
principal = var.finance_analyst_role_arn
```
to:
```hcl
principal = "arn:aws:identitystore:::group/${var.finance_analysts_group_id}"
```

**Variable changes:**
- Remove: `finance_analyst_role_arn`, `data_analyst_role_arn`, `data_engineer_role_arn`
- Add: `finance_analysts_group_id`, `data_analysts_group_id`, `data_engineers_group_id`, `sso_instance_arn`

### data-lake-storage/ (modified)

**Bucket policy update:**
The `allowed_principal_arns` variable already uses `ArnNotLike`, which supports wildcards. The identity-center module outputs a wildcard pattern:

```
arn:aws:iam::<account_id>:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_DataEngineer_*
```

This pattern matches only SSO-generated roles with the DataEngineer permission set name.

### Environment Wiring (dev/main.tf, prod/main.tf)

```hcl
# Replace module.iam_personas with two modules:

module "identity_center" {
  source                   = "../../modules/identity-center"
  environment              = var.environment
  account_id               = data.aws_caller_identity.current.account_id
  mnpi_bucket_arn          = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn       = module.data_lake_storage.nonmnpi_bucket_arn
  query_results_bucket_arn = module.data_lake_storage.query_results_bucket_arn
}

module "service_roles" {
  source                       = "../../modules/service-roles"
  environment                  = var.environment
  mnpi_bucket_arn              = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn           = module.data_lake_storage.nonmnpi_bucket_arn
  glue_registry_arn            = module.glue_catalog.registry_arn
  msk_cluster_arn              = module.streaming.cluster_arn
  eks_oidc_provider_arn        = var.eks_oidc_provider_arn
  eks_oidc_provider_url        = var.eks_oidc_provider_url
}

# data-lake-storage wiring:
module "data_lake_storage" {
  allowed_principal_arns = [
    module.identity_center.data_engineer_sso_role_pattern,
    module.service_roles.kafka_connect_role_arn,
  ]
}

# lake-formation wiring:
module "lake_formation" {
  finance_analysts_group_id = module.identity_center.finance_analysts_group_id
  data_analysts_group_id    = module.identity_center.data_analysts_group_id
  data_engineers_group_id   = module.identity_center.data_engineers_group_id
  sso_instance_arn          = module.identity_center.sso_instance_arn
  admin_role_arn            = var.admin_role_arn  # stays IAM (IC cannot be LF admin)
}
```

## Constraints

1. **IC principals cannot be Lake Formation administrators** — `admin_role_arn` stays as traditional IAM role
2. **Cross-account LF grants not supported for IC** — single-account only (acceptable for this project)
3. **AWS provider >= 5.17** required for `aws_lakeformation_identity_center_configuration` — current constraint `~> 5.0` covers this
4. **AWS Organizations required** — already set up (org: o-pkdkf9330q, account: 445985103066)
5. **SSO-generated role ARNs have random suffixes** — handled via ArnLike wildcard in bucket policy

## Demo Users

| User | Email | Group | Demonstrates |
|------|-------|-------|-------------|
| jane.finance | jane.finance@datalake.demo | FinanceAnalysts | MNPI + non-MNPI curated/analytics access |
| alex.analyst | alex.analyst@datalake.demo | DataAnalysts | Non-MNPI curated/analytics only |
| sam.engineer | sam.engineer@datalake.demo | DataEngineers | Full access + direct S3 |

## Files Changed

| Action | Path |
|--------|------|
| CREATE | `terraform/aws/modules/identity-center/main.tf` |
| CREATE | `terraform/aws/modules/identity-center/variables.tf` |
| CREATE | `terraform/aws/modules/identity-center/outputs.tf` |
| CREATE | `terraform/aws/modules/service-roles/main.tf` |
| CREATE | `terraform/aws/modules/service-roles/variables.tf` |
| CREATE | `terraform/aws/modules/service-roles/outputs.tf` |
| MODIFY | `terraform/aws/modules/lake-formation/main.tf` |
| MODIFY | `terraform/aws/modules/lake-formation/variables.tf` |
| MODIFY | `terraform/aws/modules/lake-formation/outputs.tf` |
| MODIFY | `terraform/aws/environments/dev/main.tf` |
| MODIFY | `terraform/aws/environments/dev/variables.tf` |
| MODIFY | `terraform/aws/environments/prod/main.tf` |
| MODIFY | `terraform/aws/environments/prod/variables.tf` |
| DELETE | `terraform/aws/modules/iam-personas/` (entire directory) |
| MODIFY | `docs/architecture-diagram.md` |
| MODIFY | `docs/documentation.md` |

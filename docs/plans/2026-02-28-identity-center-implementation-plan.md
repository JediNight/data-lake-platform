# Identity Center Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace IAM persona roles with IAM Identity Center groups + permission sets for human identity management, using trusted identity propagation for Lake Formation grants.

**Architecture:** Three-module split: `identity-center/` (human identities), `service-roles/` (machine identities), modified `lake-formation/` (IC configuration + IC group principals). The `iam-personas/` module is deleted.

**Tech Stack:** Terraform, AWS IAM Identity Center, AWS Lake Formation, AWS SSO Admin API

---

## Phase 1: New Modules

### Task 1: Create service-roles module

Extract the Kafka Connect IRSA role from `iam-personas/` into a standalone `service-roles/` module.

**Files:**
- Create: `terraform/aws/modules/service-roles/main.tf`
- Create: `terraform/aws/modules/service-roles/variables.tf`
- Create: `terraform/aws/modules/service-roles/outputs.tf`

**Reference:** Copy the kafka-connect role and its 3 policies from `terraform/aws/modules/iam-personas/main.tf` lines 403-557.

**Step 1: Create main.tf**

```hcl
/**
 * service-roles — Machine Identity IAM Roles
 *
 * Contains IAM roles for service-to-service authentication:
 *   1. kafka-connect-irsa — IRSA role for Strimzi KafkaConnect pods;
 *      MSK IAM auth, S3 write, Glue catalog write
 */

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  common_tags = merge(var.tags, {
    Module      = "service-roles"
    Environment = var.environment
  })
}

# =============================================================================
# Kafka Connect IRSA Role
# =============================================================================

resource "aws_iam_role" "kafka_connect" {
  name = "datalake-kafka-connect-${var.environment}"
  path = "/datalake/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEKSServiceAccountAssume"
        Effect = "Allow"
        Principal = {
          Federated = var.eks_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:${var.kafka_connect_namespace}:${var.kafka_connect_service_account}"
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name    = "datalake-kafka-connect-${var.environment}"
    Persona = "kafka-connect"
  })
}

resource "aws_iam_role_policy" "kafka_connect_msk" {
  name = "msk-iam-auth"
  role = aws_iam_role.kafka_connect.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MSKClusterAccess"
        Effect = "Allow"
        Action = [
          "kafka:DescribeCluster",
          "kafka:DescribeClusterV2",
          "kafka:GetBootstrapBrokers",
        ]
        Resource = var.msk_cluster_arn != "" ? var.msk_cluster_arn : "*"
      },
      {
        Sid    = "MSKIAMAuth"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:AlterCluster",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:AlterTopic",
          "kafka-cluster:ReadData",
          "kafka-cluster:WriteData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup",
        ]
        Resource = var.msk_cluster_arn != "" ? [
          var.msk_cluster_arn,
          "${replace(var.msk_cluster_arn, ":cluster/", ":topic/")}/*",
          "${replace(var.msk_cluster_arn, ":cluster/", ":group/")}/*",
        ] : ["*"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "kafka_connect_s3" {
  name = "s3-data-lake-write"
  role = aws_iam_role.kafka_connect.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3DataLakeWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          var.mnpi_bucket_arn,
          "${var.mnpi_bucket_arn}/*",
          var.nonmnpi_bucket_arn,
          "${var.nonmnpi_bucket_arn}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "kafka_connect_glue" {
  name = "glue-catalog-and-registry"
  role = aws_iam_role.kafka_connect.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueCatalogWriteForIceberg"
        Effect = "Allow"
        Action = [
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:DeleteTable",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:CreatePartition",
          "glue:UpdatePartition",
          "glue:DeletePartition",
          "glue:BatchCreatePartition",
          "glue:BatchDeletePartition",
          "glue:BatchGetPartition",
        ]
        Resource = "*"
      },
      {
        Sid    = "GlueSchemaRegistryRead"
        Effect = "Allow"
        Action = [
          "glue:GetSchemaVersion",
          "glue:GetSchemaByDefinition",
          "glue:GetSchemaVersionsDiff",
          "glue:ListSchemaVersions",
          "glue:GetSchema",
          "glue:ListSchemas",
          "glue:GetRegistry",
          "glue:ListRegistries",
        ]
        Resource = [
          var.glue_registry_arn,
          "${var.glue_registry_arn}/*",
          replace(var.glue_registry_arn, ":registry/", ":schema/"),
          "${replace(var.glue_registry_arn, ":registry/", ":schema/")}/*",
        ]
      },
    ]
  })
}
```

**Step 2: Create variables.tf**

```hcl
/**
 * service-roles — Variables
 *
 * Inputs for machine identity IAM roles (Kafka Connect IRSA).
 */

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "mnpi_bucket_arn" {
  description = "ARN of the MNPI data lake S3 bucket"
  type        = string
}

variable "nonmnpi_bucket_arn" {
  description = "ARN of the non-MNPI data lake S3 bucket"
  type        = string
}

variable "glue_registry_arn" {
  description = "ARN of the Glue Schema Registry"
  type        = string
}

variable "msk_cluster_arn" {
  description = "ARN of the MSK cluster for Kafka Connect IAM auth"
  type        = string
  default     = ""
}

variable "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA"
  type        = string
  default     = ""
}

variable "eks_oidc_provider_url" {
  description = "EKS OIDC provider URL (without https://)"
  type        = string
  default     = ""
}

variable "kafka_connect_namespace" {
  description = "Kubernetes namespace where KafkaConnect pods run"
  type        = string
  default     = "strimzi"
}

variable "kafka_connect_service_account" {
  description = "Kubernetes service account name for KafkaConnect pods"
  type        = string
  default     = "data-lake-connect"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
```

**Step 3: Create outputs.tf**

```hcl
/**
 * service-roles — Outputs
 */

output "kafka_connect_role_arn" {
  description = "ARN of the Kafka Connect IRSA IAM role"
  value       = aws_iam_role.kafka_connect.arn
}

output "kafka_connect_role_name" {
  description = "Name of the Kafka Connect IRSA IAM role"
  value       = aws_iam_role.kafka_connect.name
}
```

**Step 4: Validate**

Run: `cd terraform/aws/modules/service-roles && terraform init && terraform validate`
Expected: Success

**Step 5: Commit**

```bash
git add terraform/aws/modules/service-roles/
git commit -m "feat: extract kafka-connect IRSA into service-roles module"
```

---

### Task 2: Create identity-center module

Create the new Identity Center module with groups, permission sets, account assignments, and demo users.

**Files:**
- Create: `terraform/aws/modules/identity-center/main.tf`
- Create: `terraform/aws/modules/identity-center/variables.tf`
- Create: `terraform/aws/modules/identity-center/outputs.tf`

**Step 1: Create main.tf**

```hcl
/**
 * identity-center — IAM Identity Center Groups, Permission Sets & Demo Users
 *
 * Replaces iam-personas module with Identity Center-based human identity
 * management. Creates three persona groups with matching permission sets
 * and demo users for each group.
 *
 * Permission sets define the AWS-level access (Athena, Glue, S3). Lake
 * Formation LF-Tag grants (in lake-formation module) control which
 * databases/tables/columns each group can see.
 */

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.17"
    }
  }
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_ssoadmin_instances" "this" {}
data "aws_caller_identity" "current" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
  account_id        = data.aws_caller_identity.current.account_id

  common_tags = merge(var.tags, {
    Module      = "identity-center"
    Environment = var.environment
  })

  # Shared analyst policy statements (Athena + Glue read + LF GetDataAccess)
  analyst_policy_statements = [
    {
      Sid    = "AthenaQueryExecution"
      Effect = "Allow"
      Action = [
        "athena:StartQueryExecution",
        "athena:StopQueryExecution",
        "athena:GetQueryExecution",
        "athena:GetQueryResults",
        "athena:GetWorkGroup",
        "athena:BatchGetQueryExecution",
        "athena:ListQueryExecutions",
      ]
      Resource = "*"
    },
    {
      Sid    = "GlueCatalogRead"
      Effect = "Allow"
      Action = [
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetDatabase",
        "glue:GetDatabases",
        "glue:GetPartition",
        "glue:GetPartitions",
        "glue:BatchGetPartition",
      ]
      Resource = "*"
    },
    {
      Sid    = "S3QueryResultsAccess"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:AbortMultipartUpload",
      ]
      Resource = [
        var.query_results_bucket_arn,
        "${var.query_results_bucket_arn}/*",
      ]
    },
    {
      Sid      = "LakeFormationDataAccess"
      Effect   = "Allow"
      Action   = ["lakeformation:GetDataAccess"]
      Resource = "*"
    },
  ]
}

# =============================================================================
# Identity Center Groups
# =============================================================================

resource "aws_identitystore_group" "finance_analysts" {
  identity_store_id = local.identity_store_id
  display_name      = "FinanceAnalysts"
  description       = "Finance analysts with MNPI + non-MNPI curated/analytics access"
}

resource "aws_identitystore_group" "data_analysts" {
  identity_store_id = local.identity_store_id
  display_name      = "DataAnalysts"
  description       = "Data analysts with non-MNPI curated/analytics access only"
}

resource "aws_identitystore_group" "data_engineers" {
  identity_store_id = local.identity_store_id
  display_name      = "DataEngineers"
  description       = "Data engineers with full access including direct S3"
}

# =============================================================================
# Permission Sets
# =============================================================================

# --- Finance Analyst Permission Set -----------------------------------------

resource "aws_ssoadmin_permission_set" "finance_analyst" {
  name             = "FinanceAnalyst"
  description      = "Athena query access for finance analysts (LF-Tags control data visibility)"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "finance_analyst" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.finance_analyst.arn

  inline_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.analyst_policy_statements
  })
}

# --- Data Analyst Permission Set --------------------------------------------

resource "aws_ssoadmin_permission_set" "data_analyst" {
  name             = "DataAnalyst"
  description      = "Athena query access for data analysts (LF-Tags control data visibility)"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "data_analyst" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.data_analyst.arn

  inline_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.analyst_policy_statements
  })
}

# --- Data Engineer Permission Set -------------------------------------------

resource "aws_ssoadmin_permission_set" "data_engineer" {
  name             = "DataEngineer"
  description      = "Full data lake access: Athena + Glue CRUD + direct S3"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "data_engineer" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.data_engineer.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.analyst_policy_statements, [
      {
        Sid    = "GlueCatalogReadWrite"
        Effect = "Allow"
        Action = [
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:DeleteTable",
          "glue:CreatePartition",
          "glue:UpdatePartition",
          "glue:DeletePartition",
          "glue:BatchCreatePartition",
          "glue:BatchDeletePartition",
          "glue:CreateDatabase",
          "glue:UpdateDatabase",
        ]
        Resource = "*"
      },
      {
        Sid    = "DirectS3DataLakeAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          var.mnpi_bucket_arn,
          "${var.mnpi_bucket_arn}/*",
          var.nonmnpi_bucket_arn,
          "${var.nonmnpi_bucket_arn}/*",
        ]
      },
    ])
  })
}

# =============================================================================
# Account Assignments (Group + Permission Set → Account)
# =============================================================================

resource "aws_ssoadmin_account_assignment" "finance_analysts" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.finance_analyst.arn
  principal_id       = aws_identitystore_group.finance_analysts.group_id
  principal_type     = "GROUP"
  target_id          = local.account_id
  target_type        = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "data_analysts" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.data_analyst.arn
  principal_id       = aws_identitystore_group.data_analysts.group_id
  principal_type     = "GROUP"
  target_id          = local.account_id
  target_type        = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "data_engineers" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.data_engineer.arn
  principal_id       = aws_identitystore_group.data_engineers.group_id
  principal_type     = "GROUP"
  target_id          = local.account_id
  target_type        = "AWS_ACCOUNT"
}

# =============================================================================
# Demo Users (one per persona for interview demonstration)
# =============================================================================

resource "aws_identitystore_user" "finance_demo" {
  identity_store_id = local.identity_store_id
  display_name      = "Jane Finance"
  user_name         = "jane.finance"

  name {
    given_name  = "Jane"
    family_name = "Finance"
  }

  emails {
    value   = "jane.finance@datalake.demo"
    primary = true
  }
}

resource "aws_identitystore_user" "analyst_demo" {
  identity_store_id = local.identity_store_id
  display_name      = "Alex Analyst"
  user_name         = "alex.analyst"

  name {
    given_name  = "Alex"
    family_name = "Analyst"
  }

  emails {
    value   = "alex.analyst@datalake.demo"
    primary = true
  }
}

resource "aws_identitystore_user" "engineer_demo" {
  identity_store_id = local.identity_store_id
  display_name      = "Sam Engineer"
  user_name         = "sam.engineer"

  name {
    given_name  = "Sam"
    family_name = "Engineer"
  }

  emails {
    value   = "sam.engineer@datalake.demo"
    primary = true
  }
}

# =============================================================================
# Group Memberships
# =============================================================================

resource "aws_identitystore_group_membership" "finance_demo" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.finance_analysts.group_id
  member_id         = aws_identitystore_user.finance_demo.user_id
}

resource "aws_identitystore_group_membership" "analyst_demo" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.data_analysts.group_id
  member_id         = aws_identitystore_user.analyst_demo.user_id
}

resource "aws_identitystore_group_membership" "engineer_demo" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.data_engineers.group_id
  member_id         = aws_identitystore_user.engineer_demo.user_id
}
```

**Step 2: Create variables.tf**

```hcl
/**
 * identity-center — Variables
 *
 * Inputs for Identity Center groups, permission sets, and demo users.
 * Bucket ARNs are needed for permission set inline policies.
 */

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "mnpi_bucket_arn" {
  description = "ARN of the MNPI data lake S3 bucket (for DataEngineer S3 policy)"
  type        = string
}

variable "nonmnpi_bucket_arn" {
  description = "ARN of the non-MNPI data lake S3 bucket (for DataEngineer S3 policy)"
  type        = string
}

variable "query_results_bucket_arn" {
  description = "ARN of the Athena query results S3 bucket"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
```

**Step 3: Create outputs.tf**

```hcl
/**
 * identity-center — Outputs
 *
 * Exposes group IDs for Lake Formation grants and SSO role pattern
 * for bucket policy bypass.
 */

output "finance_analysts_group_id" {
  description = "Identity Center group ID for finance analysts"
  value       = aws_identitystore_group.finance_analysts.group_id
}

output "data_analysts_group_id" {
  description = "Identity Center group ID for data analysts"
  value       = aws_identitystore_group.data_analysts.group_id
}

output "data_engineers_group_id" {
  description = "Identity Center group ID for data engineers"
  value       = aws_identitystore_group.data_engineers.group_id
}

output "data_engineer_sso_role_pattern" {
  description = "ArnLike pattern for SSO-generated DataEngineer role (for bucket policy bypass)"
  value       = "arn:aws:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_DataEngineer_*"
}

output "sso_instance_arn" {
  description = "SSO instance ARN for Lake Formation IC configuration"
  value       = local.sso_instance_arn
}
```

**Step 4: Validate**

Run: `cd terraform/aws/modules/identity-center && terraform init && terraform validate`
Expected: Success

**Step 5: Commit**

```bash
git add terraform/aws/modules/identity-center/
git commit -m "feat: add identity-center module with groups, permission sets, and demo users"
```

---

## Phase 2: Modify Existing Modules

### Task 3: Update lake-formation module

Add Identity Center configuration and switch grant principals from IAM role ARNs to IC group ARNs.

**Files:**
- Modify: `terraform/aws/modules/lake-formation/main.tf`
- Modify: `terraform/aws/modules/lake-formation/variables.tf`
- Modify: `terraform/aws/modules/lake-formation/outputs.tf`

**Step 1: Update variables.tf**

Replace the three `*_role_arn` variables with IC group IDs and SSO instance ARN:

```hcl
/**
 * lake-formation -- Variables
 *
 * Inputs for LF-Tags, tag-based grants, S3 location registrations,
 * Identity Center configuration, and Lake Formation admin settings.
 */

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)"
  type        = string
}

variable "database_names" {
  description = "Map of logical name to Glue database name (from glue-catalog module)"
  type        = map(string)
}

variable "mnpi_bucket_arn" {
  description = "ARN of the MNPI data lake S3 bucket"
  type        = string
}

variable "nonmnpi_bucket_arn" {
  description = "ARN of the non-MNPI data lake S3 bucket"
  type        = string
}

variable "finance_analysts_group_id" {
  description = "Identity Center group ID for finance analysts"
  type        = string
}

variable "data_analysts_group_id" {
  description = "Identity Center group ID for data analysts"
  type        = string
}

variable "data_engineers_group_id" {
  description = "Identity Center group ID for data engineers"
  type        = string
}

variable "sso_instance_arn" {
  description = "SSO instance ARN for Lake Formation IC configuration"
  type        = string
}

variable "admin_role_arn" {
  description = "IAM role ARN for Lake Formation admin (must be IAM, not IC)"
  type        = string
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
```

**Step 2: Update main.tf**

Add the IC configuration resource after the data lake settings. Change all `principal` values. The full updated file:

- Add after `aws_lakeformation_data_lake_settings.this`:

```hcl
# =============================================================================
# Identity Center Configuration
# =============================================================================
# Connect Lake Formation to IAM Identity Center for trusted identity
# propagation. This enables granting permissions directly to IC groups
# instead of IAM role ARNs.
# =============================================================================

resource "aws_lakeformation_identity_center_configuration" "this" {
  instance_arn = var.sso_instance_arn
}
```

- Change all `principal` lines in the 9 grant resources:

Finance analyst grants:
```hcl
principal = "arn:aws:identitystore:::group/${var.finance_analysts_group_id}"
```

Data analyst grants:
```hcl
principal = "arn:aws:identitystore:::group/${var.data_analysts_group_id}"
```

Data engineer grants:
```hcl
principal = "arn:aws:identitystore:::group/${var.data_engineers_group_id}"
```

- Add `depends_on` to IC configuration for all grants:

Each grant resource should have:
```hcl
depends_on = [
  aws_lakeformation_data_lake_settings.this,
  aws_lakeformation_identity_center_configuration.this,
]
```

**Step 3: Validate**

Run: `cd terraform/aws/modules/lake-formation && terraform init && terraform validate`
Expected: Success

**Step 4: Commit**

```bash
git add terraform/aws/modules/lake-formation/
git commit -m "feat: add IC configuration and switch LF grant principals to IC groups"
```

---

### Task 4: Update data-lake-storage variable description

The bucket policy already uses `ArnNotLike` which supports wildcards. Update the variable description to reflect this.

**Files:**
- Modify: `terraform/aws/modules/data-lake-storage/variables.tf`

**Step 1: Update variable description**

Change the `allowed_principal_arns` variable description:

```hcl
variable "allowed_principal_arns" {
  description = "IAM role ARNs or ArnLike patterns allowed direct S3 access (bypassing Lake Formation deny). Supports wildcards for SSO-generated roles."
  type        = list(string)

  validation {
    condition     = length(var.allowed_principal_arns) > 0
    error_message = "At least one principal ARN must be provided for direct S3 access."
  }
}
```

**Step 2: Commit**

```bash
git add terraform/aws/modules/data-lake-storage/variables.tf
git commit -m "docs: clarify allowed_principal_arns supports ArnLike wildcards"
```

---

## Phase 3: Rewire Environments

### Task 5: Rewire dev environment

Replace `module.iam_personas` with `module.identity_center` and `module.service_roles`.

**Files:**
- Modify: `terraform/aws/environments/dev/main.tf`
- Modify: `terraform/aws/environments/dev/variables.tf`

**Step 1: Update main.tf**

Replace the `module "iam_personas"` block (lines 59-70) with:

```hcl
module "identity_center" {
  source                   = "../../modules/identity-center"
  environment              = var.environment
  mnpi_bucket_arn          = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn       = module.data_lake_storage.nonmnpi_bucket_arn
  query_results_bucket_arn = module.data_lake_storage.query_results_bucket_arn
}

module "service_roles" {
  source                        = "../../modules/service-roles"
  environment                   = var.environment
  mnpi_bucket_arn               = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn            = module.data_lake_storage.nonmnpi_bucket_arn
  glue_registry_arn             = module.glue_catalog.registry_arn
  msk_cluster_arn               = module.streaming.cluster_arn
  eks_oidc_provider_arn         = var.eks_oidc_provider_arn
  eks_oidc_provider_url         = var.eks_oidc_provider_url
}
```

Update `module "data_lake_storage"` allowed_principal_arns (lines 35-38):

```hcl
module "data_lake_storage" {
  source      = "../../modules/data-lake-storage"
  environment = var.environment
  allowed_principal_arns = [
    module.identity_center.data_engineer_sso_role_pattern,
    module.service_roles.kafka_connect_role_arn,
  ]
  raw_ia_transition_days = var.raw_ia_transition_days
}
```

Update `module "lake_formation"` (lines 72-82):

```hcl
module "lake_formation" {
  source                    = "../../modules/lake-formation"
  environment               = var.environment
  database_names            = module.glue_catalog.database_names
  mnpi_bucket_arn           = module.data_lake_storage.mnpi_bucket_arn
  nonmnpi_bucket_arn        = module.data_lake_storage.nonmnpi_bucket_arn
  finance_analysts_group_id = module.identity_center.finance_analysts_group_id
  data_analysts_group_id    = module.identity_center.data_analysts_group_id
  data_engineers_group_id   = module.identity_center.data_engineers_group_id
  sso_instance_arn          = module.identity_center.sso_instance_arn
  admin_role_arn            = var.admin_role_arn
}
```

**Step 2: Validate**

Run: `cd terraform/aws/environments/dev && terraform init && terraform validate`
Expected: Success

**Step 3: Commit**

```bash
git add terraform/aws/environments/dev/
git commit -m "feat: rewire dev environment to identity-center and service-roles modules"
```

---

### Task 6: Rewire prod environment

Same changes as dev.

**Files:**
- Modify: `terraform/aws/environments/prod/main.tf`

**Step 1: Apply identical changes as Task 5**

Same three block replacements in prod/main.tf.

**Step 2: Validate**

Run: `cd terraform/aws/environments/prod && terraform init && terraform validate`
Expected: Success

**Step 3: Commit**

```bash
git add terraform/aws/environments/prod/
git commit -m "feat: rewire prod environment to identity-center and service-roles modules"
```

---

## Phase 4: Cleanup & Documentation

### Task 7: Delete iam-personas module

**Files:**
- Delete: `terraform/aws/modules/iam-personas/` (entire directory)

**Step 1: Remove the directory**

```bash
rm -rf terraform/aws/modules/iam-personas/
```

**Step 2: Verify no remaining references**

```bash
grep -r "iam.personas\|iam_personas" terraform/
```

Expected: No matches.

**Step 3: Commit**

```bash
git add -A terraform/aws/modules/iam-personas/
git commit -m "refactor: remove iam-personas module (replaced by identity-center + service-roles)"
```

---

### Task 8: Validate both environments

**Step 1: Validate dev**

```bash
cd terraform/aws/environments/dev && terraform init && terraform validate
```

**Step 2: Validate prod**

```bash
cd terraform/aws/environments/prod && terraform init && terraform validate
```

Expected: Both succeed with no errors.

---

### Task 9: Update documentation

**Files:**
- Modify: `docs/architecture-diagram.md` — update Terraform module dependency graph and access control diagrams
- Modify: `docs/documentation.md` — replace IAM personas section with Identity Center section

**Key changes to architecture diagram:**
- Replace `iam-personas` node with `identity-center` and `service-roles` nodes
- Update dependency arrows
- Update access control matrix description

**Key changes to documentation:**
- Replace "IAM Personas" section with "Identity Center" section
- Describe groups, permission sets, demo users
- Note that `admin_role_arn` stays as traditional IAM
- Add SSO login instructions

**Step 1: Update diagrams and docs**

**Step 2: Commit**

```bash
git add docs/
git commit -m "docs: update architecture diagrams and documentation for Identity Center"
```

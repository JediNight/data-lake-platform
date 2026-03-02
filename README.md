# Data Lake Platform

Secure, auditable AWS data lake with MNPI/non-MNPI isolation for an asset management firm.

Real-time CDC and streaming ingestion into Apache Iceberg tables on S3, with Lake Formation attribute-based access control (ABAC) and a medallion architecture powered by Glue ETL.

![Architecture Diagram](generated-diagrams/data-lake-architecture.png)

## Key Capabilities

| Capability | Implementation |
|---|---|
| **CDC Pipeline** | Aurora PostgreSQL &rarr; Debezium (MSK Connect) &rarr; MSK &rarr; Iceberg Sink &rarr; S3 |
| **Streaming Ingestion** | Lambda trading simulator &rarr; MSK &rarr; Iceberg Sink &rarr; S3 |
| **MNPI Isolation** | Separate S3 buckets, KMS CMKs, Kafka topics, Glue databases per sensitivity zone |
| **Lake Formation ABAC** | LF-Tags (`sensitivity` + `layer`) with grants per IAM Identity Center group |
| **Medallion Transforms** | Glue PySpark jobs: Raw &rarr; Curated (dedup + type cast) &rarr; Analytics (aggregates) |
| **Iceberg Tables** | Schema evolution, snapshot history, time-travel, Parquet data files |
| **BI / Reporting** | 3 Athena workgroups + QuickSight data source (via Athena connector) |
| **Infrastructure as Code** | 14 Terraform modules, workspace-driven dev/prod, ~200 resources |

## Architecture

### Data Flow

```
EventBridge (1 min) ──► Lambda Trading Simulator
                             │
                             ├──► Aurora PostgreSQL (RDS Data API)
                             │       └──► Debezium CDC (WAL) ──► MSK
                             │                                    │
                             └──► MSK (direct produce: market data)
                                                              │
                                  MSK Connect Iceberg Sinks ◄─┘
                                       │
                             ┌─────────┼──────────┐
                             ▼                     ▼
                           S3 MNPI Bucket     S3 Non-MNPI Bucket
                           (Iceberg tables)   (Iceberg tables)
                             │                     │
                             └─────────┬───────────┘
                                       ▼
                              Glue ETL (4 PySpark jobs)
                              raw → curated → analytics
                                       │
                                       ▼
                              Athena (3 workgroups)
                                       │
                                       ▼
                              QuickSight dashboards
```

### Access Control Model (ABAC via Lake Formation)

| Persona | Sensitivity | Layers | Permission |
|---|---|---|---|
| **Finance Analyst** | mnpi + non-mnpi | curated, analytics | SELECT |
| **Data Analyst** | non-mnpi only | curated, analytics | SELECT |
| **Data Engineer** | mnpi + non-mnpi | raw, curated, analytics | ALL + DATA_LOCATION_ACCESS |

Data Analysts querying MNPI tables receive `AccessDeniedException` from Lake Formation. Grants use LF-Tag expressions (AND across tag keys, OR within values) so new tables automatically inherit permissions.

### Medallion Layers

| Layer | MNPI Database | Non-MNPI Database | Description |
|---|---|---|---|
| **Raw** | `raw_mnpi_{env}` | `raw_nonmnpi_{env}` | Append-only CDC/streaming events |
| **Curated** | `curated_mnpi_{env}` | `curated_nonmnpi_{env}` | Deduplicated, typed, enriched |
| **Analytics** | `analytics_mnpi_{env}` | `analytics_nonmnpi_{env}` | Pre-aggregated summaries |

## Project Structure

```
terraform/aws/                AWS infrastructure (14 modules, workspace-driven dev/prod)
  modules/
    networking/               VPC, subnets, NAT GW, S3 + STS endpoints, security groups
    data-lake-storage/        S3 buckets (MNPI + non-MNPI + audit + query-results), KMS CMKs
    streaming/                MSK Provisioned cluster
    glue-catalog/             6 Glue databases across medallion layers
    glue-etl/                 4 PySpark jobs, workflow with conditional triggers
    identity-center/          3 IAM IC groups + permission sets + demo users
    lake-formation/           LF-Tags, tag-based ABAC grants, S3 registrations, IC integration
    service-roles/            IAM roles (Kafka Connect, Glue ETL, Lambda) with least-privilege
    analytics/                3 Athena workgroups + named queries
    observability/            CloudTrail, QuickSight data source, CloudWatch log groups
    aurora-postgres/          Aurora PostgreSQL 15 (CDC source, prod only)
    msk-connect/              Debezium source + 2 Iceberg sinks via MSK Connect (prod only)
    lambda-producer/          Lambda trading simulator + EventBridge schedule (prod only)
    local-dev-storage/        S3 bucket for local Iceberg data (dev only)
scripts/
  lambda/trading_simulator/   Lambda source: simulator, Kafka producer, RDS Data API client
  glue/                       4 PySpark ETL scripts (uploaded to S3 by Terraform)
  01_curated/                 Athena SQL proving curated transforms
  02_analytics/               Athena SQL proving analytics transforms
  validation/                 Access control + Iceberg time-travel validation queries
  init-aurora-cdc.sh          Aurora CDC setup (replication slot, publication, seed tables)
  upload-connector-plugins.sh Download + repackage Debezium & Iceberg connector JARs
  build_lambda.sh             Build Lambda deployment artifacts (.build/ directory)
docs/
  documentation.md            Full platform documentation (security, data model, ETL, etc.)
  plans/                      Design and implementation documents
```

> **Local development code** (Kind, ArgoCD, Strimzi, FastAPI producer-api, Tiltfile) lives on the [`dev`](../../tree/dev) branch. The local environment validates the same CDC + Iceberg pipeline using Strimzi Kafka Connect in a Kind cluster before deploying to AWS.

## Deployment

### Prerequisites

- Terraform >= 1.7.0
- AWS CLI v2 with SSO configured (`aws sso login --profile data-lake`)

### Deploy

```bash
# Authenticate
aws sso login --profile data-lake

# Initialize and select workspace
task aws:init TF_WORKSPACE=prod

# Review the plan (~200 resources)
task aws:plan TF_WORKSPACE=prod

# Apply
task aws:apply TF_WORKSPACE=prod
```

### Post-Deploy Steps

```bash
# 1. Build and deploy Lambda trading simulator
./scripts/build_lambda.sh
terraform -chdir=terraform/aws apply -var-file=prod.tfvars

# 2. Upload MSK Connect plugin JARs (one-time)
./scripts/upload-connector-plugins.sh prod

# 3. Initialize Aurora CDC (replication slot + publication + seed 5 tables)
./scripts/init-aurora-cdc.sh prod

# 4. Enable connectors (set enable_debezium_connector = true, re-apply)
task aws:apply TF_WORKSPACE=prod

# 5. Run Glue medallion workflow
AWS_PROFILE=data-lake aws glue start-workflow-run --name datalake-medallion-prod

# 6. Verify data flow end-to-end
task athena:query QUERY="SELECT count(*) FROM raw_mnpi_prod.mnpi_events" WORKGROUP=data-engineers-prod
```

### Terraform Modules

| Module | Resources | Key Outputs |
|---|---|---|
| networking | VPC, 2 private + 1 public subnet, NAT GW, S3/STS endpoints, SGs | `vpc_id`, `private_subnet_ids` |
| data-lake-storage | 4 S3 buckets, 2 KMS CMKs, DENY bucket policies | `mnpi_bucket_id`, KMS ARNs |
| streaming | MSK cluster (IAM auth, TLS in-transit) | `bootstrap_brokers` |
| glue-catalog | 6 databases, schema registry | `database_names` |
| glue-etl | 4 PySpark jobs, workflow, conditional triggers | `workflow_name`, `job_names` |
| identity-center | 3 groups, 3 permission sets, 3 demo users | `*_group_id` |
| lake-formation | 2 LF-Tags, 14 grants, 2 S3 registrations, IC config | LF admin configured |
| service-roles | Kafka Connect + Glue ETL + Lambda IAM roles | `*_role_arn` |
| analytics | 3 Athena workgroups | `workgroup_names` |
| observability | CloudTrail, QuickSight, CloudWatch | `cloudtrail_arn` |
| aurora-postgres | Aurora PG 15, Secrets Manager | `cluster_endpoint` |
| msk-connect | Debezium source + 2 Iceberg sinks (for_each) | `connector_arns` |
| lambda-producer | Lambda + EventBridge schedule (1 min) | `function_name` |

### Security Highlights

- **S3 DENY bucket policies** block all `s3:GetObject`/`s3:PutObject` except Lake Formation SLR and explicitly allowed IAM roles
- **KMS CMK per sensitivity zone** — MNPI and non-MNPI data encrypted with separate keys
- **MSK IAM auth + TLS** — no plaintext Kafka traffic, IAM-based ACLs
- **Lake Formation overrides IAM** — removing default `IAMAllowedPrincipals` forces all access through LF grants
- **Secrets Manager** for Aurora credentials (not in Terraform state)
- **CloudTrail** audit logging to dedicated S3 bucket with 5-year retention (SEC Rule 204-2)

## Design Documents

- [`docs/documentation.md`](docs/documentation.md) — Full platform documentation (data model, security, ETL lineage, deployment)
- [`docs/plans/`](docs/plans/) — Design and implementation plans

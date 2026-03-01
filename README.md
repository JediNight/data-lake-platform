# Data Lake Platform

Secure, auditable AWS Data Lake with MNPI/non-MNPI isolation for an asset management firm.

Real-time CDC and streaming ingestion into Apache Iceberg tables on S3, queryable via Athena with Lake Formation attribute-based access control (ABAC).

## What This Demonstrates

| Capability | Implementation |
|---|---|
| **CDC Pipeline** | PostgreSQL -> Debezium -> Kafka -> Iceberg Sink -> S3 (Iceberg v2) |
| **Streaming Ingestion** | FastAPI trading simulator -> Kafka -> Iceberg Sink -> S3 |
| **MNPI Isolation** | Separate S3 buckets, KMS keys, Kafka topics, Glue databases |
| **Lake Formation ABAC** | LF-Tags (sensitivity + layer) grant access per Identity Center group |
| **Iceberg Format** | Schema evolution, snapshot history, time-travel, Parquet data files |
| **Medallion Architecture** | Raw (append-only CDC) -> Curated (MERGE INTO) -> Analytics (CTAS aggregates) |
| **Infrastructure as Code** | 10 Terraform modules, workspace-driven dev/prod, GitOps via ArgoCD |

## Prerequisites

- [Terraform](https://terraform.io) >= 1.7.0
- [Kind](https://kind.sigs.k8s.io/) >= 0.20
- [Task](https://taskfile.dev/) >= 3.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/) >= 1.28
- AWS CLI v2 with SSO configured (`aws sso login --profile data-lake`)
- Python 3.11+ (for producer-api)

## Quick Start

```bash
task up          # Bootstrap Kind + ArgoCD + deploy workloads
task status      # Check all resources
task down        # Tear down everything
```

## Demo Walkthrough

### 1. Start the Local Pipeline

```bash
# Bootstrap Kind cluster with ArgoCD, Strimzi, and sample Postgres
task infra

# Watch ArgoCD sync all workloads
kubectl -n argocd get applications -w

# Verify the pipeline components are running
task status
```

### 2. Generate Trading Data

The producer-api generates simulated trading data (order events + market data ticks) and writes to Kafka:

```bash
# Check the producer pod is running
kubectl -n data get pods -l app=producer-api

# Tail producer logs to see data flowing
kubectl -n data logs -f deployment/producer-api
```

Debezium captures CDC events from PostgreSQL, and both CDC + streaming events flow through Kafka into Iceberg tables on S3.

### 3. Verify Data Landed in Iceberg

```bash
# Check Iceberg files in the local dev S3 bucket
aws s3 ls s3://datalake-local-iceberg-dev/mnpi/default/mnpi_events/data/ \
  --profile data-lake --recursive | head -5
aws s3 ls s3://datalake-local-iceberg-dev/nonmnpi/default/nonmnpi_events/data/ \
  --profile data-lake --recursive | head -5
```

### 4. Query with Athena

The Iceberg tables are registered in AWS Glue and queryable via Athena engine v3.

```sql
-- Count all MNPI order events
SELECT count(*) AS total_rows FROM raw_mnpi_dev.mnpi_events;
-- Result: ~5,500 rows

-- Sample MNPI data (order book events)
SELECT ticker, side, event_type, quantity, order_id, timestamp
FROM raw_mnpi_dev.mnpi_events
WHERE event_type = 'ORDER_CREATED'
LIMIT 10;

-- Count non-MNPI market data ticks
SELECT count(*) AS total_rows FROM raw_nonmnpi_dev.nonmnpi_events;
-- Result: ~1,100 rows

-- Price summary per ticker (non-MNPI public market data)
SELECT
    ticker,
    count(*) AS tick_count,
    min(CAST(bid AS double)) AS min_bid,
    max(CAST(ask AS double)) AS max_ask,
    round(avg(CAST(last_price AS double)), 2) AS avg_price
FROM raw_nonmnpi_dev.nonmnpi_events
GROUP BY ticker
ORDER BY tick_count DESC;
```

Run queries via the AWS Console (Athena > Query Editor) using the `data-engineers-dev` workgroup, or via CLI:

```bash
aws athena start-query-execution \
  --query-string "SELECT count(*) FROM raw_mnpi_dev.mnpi_events" \
  --work-group data-engineers-dev \
  --profile data-lake
```

### 5. Access Control (ABAC)

Three Identity Center groups with different access levels:

| Persona | Sensitivity | Layers | Permission |
|---|---|---|---|
| **Finance Analyst** | mnpi + non-mnpi | curated, analytics | SELECT |
| **Data Analyst** | non-mnpi only | curated, analytics | SELECT |
| **Data Engineer** | mnpi + non-mnpi | raw, curated, analytics | ALL + S3 |

Data Analysts querying MNPI tables get `AccessDeniedException` from Lake Formation. See `scripts/validation/access_validation.sql` for test queries.

### 6. Medallion Layer Transforms

```bash
# Raw -> Curated (deduplicate CDC events to current state)
# Run in Athena as data-engineer:
cat scripts/01_curated/curated_orders.sql

# Curated -> Analytics (pre-aggregated reports)
cat scripts/02_analytics/analytics_trade_summary.sql
```

## Architecture

See [Architecture Diagrams](docs/architecture-diagram.md) for Mermaid diagrams covering:
- End-to-end data flow
- MNPI/non-MNPI isolation boundary
- Access control matrix (persona -> LF-Tags -> databases)
- Terraform module dependency graph
- Medallion layer detail

Full design doc: [Architecture Design](docs/plans/2026-02-28-data-lake-platform-design.md)

## Project Structure

```
terraform/local/          Kind cluster + ArgoCD bootstrap (GitOps bridge)
terraform/aws/            AWS infrastructure (10 modules, workspace-driven dev/prod)
  modules/
    networking/           VPC, subnets, security groups, S3 gateway endpoint
    data-lake-storage/    S3 buckets (MNPI + non-MNPI + audit + query-results), KMS
    streaming/            MSK Provisioned (prod only)
    glue-catalog/         6 Glue databases, schema registry
    identity-center/      3 IC groups + permission sets + demo users
    lake-formation/       LF-Tags, ABAC grants, S3 registrations
    service-roles/        Kafka Connect IRSA role
    analytics/            3 Athena workgroups + named queries
    observability/        CloudTrail + audit logging
    eks/                  EKS cluster (prod only)
    aurora-postgres/      Aurora PostgreSQL (prod only)
    msk-connect/          MSK Connect connectors (prod only)
strimzi/                  Kafka + KafkaConnect + Debezium + Iceberg sinks (Kustomize)
sample-postgres/          Source PostgreSQL for CDC demo (Kustomize)
producer-api/             FastAPI trading simulator + Alpaca market data adapter
scripts/
  00_seed/                Initial data seeding
  01_curated/             Raw -> Curated MERGE INTO transforms
  02_analytics/           Curated -> Analytics CTAS aggregates
  integration/            Local integration test suite
  validation/             Access control + Iceberg time-travel validation queries
docs/                     Architecture diagrams and design plans
```

## AWS Infrastructure (dev environment)

The `dev` workspace deploys ~90 resources:

| Module | Resources | Key Outputs |
|---|---|---|
| networking | VPC, 2 private subnets, S3 endpoint | `vpc_id`, `private_subnet_ids` |
| data-lake-storage | 4 S3 buckets, 2 KMS CMKs | `mnpi_bucket_id`, `nonmnpi_bucket_id` |
| glue-catalog | 6 databases, schema registry | `database_names`, `registry_arn` |
| identity-center | 3 groups, permission sets | `*_group_id` |
| lake-formation | 2 LF-Tags, 8 grants, 2 S3 registrations | LF admin configured |
| analytics | 3 Athena workgroups | `workgroup_names` |
| observability | CloudTrail, audit bucket | `cloudtrail_arn` |

MSK, EKS, Aurora, and MSK Connect are enabled in `prod` only.

```bash
# Deploy AWS dev infrastructure
aws sso login --profile data-lake
task aws:init
task aws:plan
task aws:apply
```

## Testing

```bash
task test:unit          # Producer-api pytest (28 unit tests)
task alpaca:test        # Alpaca adapter transform tests (8 tests)
task test:integration   # Local pipeline integration tests
task validate:tf        # Terraform validate (local + AWS)
```

# Data Lake Platform Documentation

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Model](#2-data-model)
3. [Security Architecture](#3-security-architecture)
4. [Deployment Guide](#4-deployment-guide)
5. [Query Examples](#5-query-examples)
6. [Trading Simulator](#6-trading-simulator)
7. [Glue ETL Pipeline](#7-glue-etl-pipeline)
8. [Production Infrastructure](#8-production-infrastructure)
9. [Decision Log](#9-decision-log)

---

## 1. Architecture Overview

This platform is a secure, auditable, and scalable AWS data lake for an asset management firm. It ingests financial data via Change Data Capture (CDC) from Aurora PostgreSQL and direct Kafka streaming, stores it in a medallion architecture (raw, curated, analytics) with strict MNPI/non-MNPI isolation, transforms it through Glue ETL PySpark jobs, and provides role-based query access through Athena with Lake Formation enforcement.

### Architecture Diagram

See [`generated-diagrams/data-lake-architecture.png`](../generated-diagrams/data-lake-architecture.png) for the full visual diagram.

### Data Flow

The platform is fully serverless in production — no EKS, no self-managed compute. All workloads run on managed AWS services.

```
                             ┌─────────────────────────────────────────────────┐
                             │              Production (prod workspace)        │
                             │                                                 │
EventBridge (1 min) ──► Lambda Trading Simulator                               │
                             │    │                                            │
                             │    ├──► Aurora PostgreSQL (RDS Data API)         │
                             │    │       └──► Debezium CDC (WAL) ──► MSK      │
                             │    │                                    │        │
                             │    └──► MSK (direct produce: market data)│       │
                             │                                    │    │        │
                             │         MSK Connect Iceberg Sinks ◄┘    │        │
                             │              │                          │        │
                             │    ┌─────────┼──────────┐               │        │
                             │    ▼                     ▼              │        │
                             │  S3 MNPI Bucket     S3 Non-MNPI Bucket  │        │
                             │  (Iceberg tables)   (Iceberg tables)    │        │
                             │    │                     │              │        │
                             │    └─────────┬───────────┘              │        │
                             │              ▼                          │        │
                             │     Glue ETL (4 PySpark jobs)           │        │
                             │     raw → curated → analytics           │        │
                             │              │                          │        │
                             │              ▼                          │        │
                             │     Athena (3 workgroups)               │        │
                             │              │                          │        │
                             │              ▼                          │        │
                             │     QuickSight dashboards               │        │
                             └─────────────────────────────────────────────────┘
```

**Two ingestion paths:**

1. **CDC path** (MNPI orders/trades/positions): Lambda inserts rows into Aurora PostgreSQL via the RDS Data API. Debezium captures WAL changes and streams them through MSK. MSK Connect Iceberg sinks write to S3 as raw Iceberg tables.
2. **Streaming path** (non-MNPI market data): Lambda produces market data ticks directly to MSK. The non-MNPI Iceberg sink writes them to S3.

**Medallion layers:**

| Layer | Purpose | Transform Engine | Storage |
|-------|---------|-----------------|---------|
| **Raw** | Full CDC event history (append-only) | MSK Connect Iceberg Sink | Partitioned by `days(source_timestamp)` |
| **Curated** | Cleaned, deduped, typed current-state | Glue ETL PySpark | Iceberg MERGE/overwrite |
| **Analytics** | Pre-aggregated reporting tables | Glue ETL PySpark | Iceberg overwrite |

Each layer is replicated across MNPI and non-MNPI zones, yielding 6 Glue Catalog databases: `raw_mnpi`, `raw_nonmnpi`, `curated_mnpi`, `curated_nonmnpi`, `analytics_mnpi`, `analytics_nonmnpi`.

### Project Structure

```
data-lake-platform/
├── Taskfile.yml                         # Lifecycle tasks (up, down, status, aws:*)
├── Tiltfile                             # Local dev loop (Kind + ArgoCD + Tilt)
├── kind-config.yaml                     # Kind cluster: 1 CP + 1 worker
├── appset-management.yaml               # ArgoCD root ApplicationSet
├── .sops.yaml                           # Age encryption config
│
├── terraform/
│   ├── local/                           # Kind + ArgoCD bootstrap
│   └── aws/
│       ├── main.tf                      # Root module (AWS provider ~> 6.0)
│       ├── locals.tf                    # Per-environment config (dev | prod)
│       ├── backend.tf                   # S3 state backend (native S3 locking)
│       ├── dev.tfvars / prod.tfvars     # Environment-specific variable overrides
│       └── modules/
│           ├── networking/              # VPC, subnets, NAT GW, S3 + STS endpoints, SGs
│           ├── data-lake-storage/       # 4 S3 buckets, 2 KMS CMKs, DENY policies
│           ├── streaming/               # MSK Provisioned cluster
│           ├── glue-catalog/            # 6 Glue databases, schema registry
│           ├── glue-etl/                # 4 PySpark jobs, medallion workflow, triggers
│           ├── identity-center/         # 3 IC groups, permission sets, demo users
│           ├── service-roles/           # IAM roles: Kafka Connect, Glue ETL, Lambda
│           ├── lake-formation/          # LF-Tags, ABAC grants, S3 registrations
│           ├── analytics/               # 3 Athena workgroups, named queries
│           ├── observability/           # CloudTrail, QuickSight, CloudWatch
│           ├── aurora-postgres/         # Aurora PG 15 cluster (prod only)
│           ├── msk-connect/             # Debezium source + 2 Iceberg sinks (prod only)
│           ├── lambda-producer/         # Trading simulator Lambda + EventBridge (prod only)
│           └── local-dev-storage/       # S3 bucket for local Iceberg data (dev only)
│
├── gitops/                              # Kubernetes manifests (ArgoCD-managed)
│   ├── strimzi/                         # KafkaConnect + connectors (local dev)
│   ├── sample-postgres/                 # PostgreSQL StatefulSet (local dev)
│   └── strimzi-operator/               # Strimzi Helm chart
│
├── producer-api/                        # FastAPI trading simulator (local dev)
│   ├── app/                             # Main application code
│   ├── alpaca_adapter/                  # Alpaca market data adapter
│   └── tests/                           # 28 unit tests
│
├── scripts/
│   ├── lambda/trading_simulator/        # Lambda source code (prod)
│   ├── glue/                            # 4 PySpark ETL scripts
│   ├── 00_seed/                         # Database seeding SQL
│   ├── 01_curated/                      # Athena SQL curated transforms (dev validation)
│   ├── 02_analytics/                    # Athena SQL analytics transforms (dev validation)
│   ├── validation/                      # Access control + Iceberg time-travel queries
│   ├── init-aurora-cdc.sh               # Aurora CDC setup (replication slot, publication)
│   ├── upload-connector-plugins.sh      # Download + repackage connector JARs as ZIPs
│   └── build_lambda.sh                  # Build Lambda deployment artifacts
│
├── docs/
│   ├── plans/                           # Design and implementation documents
│   └── documentation.md                 # This file
│
└── tests/                               # Unit + Alpaca adapter tests (36 total)
```

---

## 2. Data Model

### Source Tables (Aurora PostgreSQL)

The platform captures 5 tables from a PostgreSQL trading database. In local dev, these live in a Kind-hosted PostgreSQL StatefulSet. In production, they live in Aurora PostgreSQL 15 with CDC enabled (logical replication).

**Schema definition:** [`scripts/init-aurora-cdc.sh`](../scripts/init-aurora-cdc.sh) (production) / [`gitops/sample-postgres/base/init-schema.sql`](../gitops/sample-postgres/base/init-schema.sql) (local dev)

#### MNPI Tables

| Table | Key Fields | MNPI Rationale |
|-------|-----------|----------------|
| **orders** | `order_id`, `account_id`, `instrument_id`, `side`, `quantity`, `order_type`, `status`, `disclosure_status` | Non-public trading intent: which accounts are buying/selling what, before execution. Classic insider information under SEC regulations. |
| **trades** | `trade_id`, `order_id`, `instrument_id`, `quantity`, `price`, `execution_venue`, `settlement_date`, `disclosure_status` | Non-public execution data: fill prices, quantities, venues before public disclosure. |
| **positions** | `position_id`, `account_id`, `instrument_id`, `quantity`, `market_value`, `position_date` | Non-public holdings: aggregate exposure per instrument per account. Reveals portfolio composition before regulatory filings (13F). |

#### Non-MNPI Tables

| Table | Key Fields | Non-MNPI Rationale |
|-------|-----------|-------------------|
| **accounts** | `account_id`, `account_name`, `account_type`, `status` | Internal reference/metadata. Account names and types do not reveal trading activity. |
| **instruments** | `instrument_id`, `ticker`, `cusip`, `isin`, `name`, `instrument_type`, `exchange` | Publicly available reference data from exchanges and data vendors. |

### CDC Topics (created by Debezium)

| Topic | Zone | Source Table |
|-------|------|-------------|
| `cdc.trading.orders` | MNPI | orders |
| `cdc.trading.trades` | MNPI | trades |
| `cdc.trading.positions` | MNPI | positions |
| `cdc.trading.accounts` | Non-MNPI | accounts |
| `cdc.trading.instruments` | Non-MNPI | instruments |

### Streaming Topics

| Topic | Zone | Source |
|-------|------|--------|
| `stream.market-data` | Non-MNPI | Lambda trading simulator (direct Kafka produce) |

### MNPI Routing

MNPI classification is **structural** (topic-per-sink), not runtime per-row:

- **MNPI Iceberg sink** subscribes to: `cdc.trading.orders`, `cdc.trading.trades`, `cdc.trading.positions`
- **Non-MNPI Iceberg sink** subscribes to: `cdc.trading.accounts`, `cdc.trading.instruments`, `stream.market-data`

The MSK Connect module drives this via a `for_each` config map in [`modules/msk-connect/main.tf`](../terraform/aws/modules/msk-connect/main.tf), where each data zone (mnpi/nonmnpi) maps to its topic list, target bucket, and Iceberg table names.

**Known limitation:** All trades remain in the MNPI zone permanently, even after public disclosure. The `disclosure_status` field provides temporal metadata for analytics within the MNPI zone.

### Iceberg Table Design

| Layer | Write Mode | Engine |
|-------|-----------|--------|
| Raw | Append-only (full CDC event history) | MSK Connect Iceberg Sink |
| Curated | Dedup + type cast + derived columns | Glue ETL PySpark (`createOrReplace`) |
| Analytics | Group-by aggregations | Glue ETL PySpark (`createOrReplace`) |

The raw layer preserves every CDC operation (create, update, delete) as an immutable append. Iceberg snapshots enable querying the raw layer at any historical point in time.

---

## 3. Security Architecture

### MNPI Isolation via Separate S3 Buckets and KMS Keys

**Module:** [`modules/data-lake-storage`](../terraform/aws/modules/data-lake-storage/main.tf)

| Bucket | KMS Key | Purpose |
|--------|---------|---------|
| `datalake-mnpi-{env}` | `alias/datalake-mnpi-{env}` | Orders, trades, positions (MNPI) |
| `datalake-nonmnpi-{env}` | `alias/datalake-nonmnpi-{env}` | Accounts, instruments, market data (non-MNPI) |
| `datalake-audit-{env}` | Non-MNPI CMK | CloudTrail audit logs |
| `datalake-query-results-{account}-{env}` | Non-MNPI CMK | Athena query results, Glue scripts |

Both data lake buckets have versioning enabled, all public access blocked, and KMS key rotation enabled on both CMKs.

### S3 Bucket DENY Policies

Both data lake buckets carry a bucket policy that **DENIES** `s3:GetObject` and `s3:PutObject` for all principals except:

1. **Lake Formation service-linked role** — vends temporary credentials for Athena queries
2. **Kafka Connect role** (`service-roles` module) — direct S3 write for Iceberg sink connectors
3. **Glue ETL role** (`service-roles` module) — reads raw, writes curated + analytics
4. **DataEngineer SSO role** (wildcard `ArnLike` pattern) — direct S3 access for ad hoc work

Without this policy, any IAM principal with `s3:GetObject` could read data directly from S3, bypassing Lake Formation column/row-level security.

### Lake Formation LF-Tags (Attribute-Based Access Control)

**Module:** [`modules/lake-formation`](../terraform/aws/modules/lake-formation/main.tf)

Two LF-Tag keys control access across all 6 Glue databases:

| Tag Key | Values | Purpose |
|---------|--------|---------|
| `sensitivity` | `mnpi`, `non-mnpi` | Controls which data zone a principal can access |
| `layer` | `raw`, `curated`, `analytics` | Controls which medallion layer a principal can access |

New tables added to any database **automatically inherit** its LF-Tags, so grants apply without Terraform changes. The default `IAMAllowedPrincipals` is removed from Lake Formation settings, forcing all data access through LF grants.

### Identity Center Groups and Access Levels

**Modules:** [`modules/identity-center`](../terraform/aws/modules/identity-center/) (human identities) and [`modules/service-roles`](../terraform/aws/modules/service-roles/) (machine identities)

| IC Group | LF-Tag Grant | Athena Workgroup | Direct S3 |
|----------|-------------|-----------------|-----------|
| **FinanceAnalysts** | `SELECT` where `sensitivity IN (mnpi, non-mnpi)` AND `layer IN (curated, analytics)` | `finance-analysts` (scan-limited) | No |
| **DataAnalysts** | `SELECT` where `sensitivity = non-mnpi` AND `layer IN (curated, analytics)` | `data-analysts` (scan-limited) | No |
| **DataEngineers** | `ALL` where `sensitivity IN (mnpi, non-mnpi)` AND `layer IN (raw, curated, analytics)` + `DATA_LOCATION_ACCESS` | `data-engineers` (unlimited) | Yes |

**Demo users:** `jane.finance@datalake.demo` (FinanceAnalysts), `alex.analyst@datalake.demo` (DataAnalysts), `sam.engineer@datalake.demo` (DataEngineers).

### Machine Identity (Service Roles)

All machine IAM roles live in `modules/service-roles` with a `/datalake/` IAM path and least-privilege policies:

| Role | Purpose | Key Permissions |
|------|---------|----------------|
| `datalake-kafka-connect-{env}` | MSK Connect connectors | S3 read/write on data buckets, MSK cluster + topic access, Glue catalog, KMS |
| `datalake-glue-etl-{env}` | Glue ETL PySpark jobs | S3 read/write on data buckets, Glue catalog CRUD, CloudWatch Logs, KMS, scripts bucket read |
| `datalake-trading-simulator-{env}` | Lambda trading simulator | MSK topic produce, RDS Data API, Secrets Manager read, VPC access |

### Endpoint Security

| Connection | Security Mechanism |
|------------|-------------------|
| Lambda → Aurora | RDS Data API (HTTPS, no direct PG connection) |
| Lambda → MSK | IAM auth (SASL_SSL/OAUTHBEARER) via STS VPC endpoint |
| Debezium → Aurora | SSL mode `require` (Aurora PG 15 enforces SSL) |
| Debezium → MSK | IAM authentication + TLS in-transit |
| Iceberg Sink → S3 | IAM role scoped to target bucket ARN |
| Athena → S3 | Lake Formation temporary scoped credentials |
| S3 at rest | KMS-SSE encryption, separate CMK per zone |

**Networking:** Private subnets only for all workloads. NAT Gateway in a public subnet for Lambda outbound. S3 VPC gateway endpoint keeps Iceberg writes within the AWS network. STS VPC interface endpoint enables MSK IAM token generation without NAT.

### Audit Trail

**Module:** [`modules/observability`](../terraform/aws/modules/observability/main.tf)

1. **CloudTrail** — S3 data events on both data lake buckets. Every `ReadObject`/`WriteObject` is logged. Log file validation enabled for tamper detection.
2. **Lake Formation** — Audit logs capture all LF grant evaluations.
3. **Athena** — Workgroup CloudWatch metrics track query counts, bytes scanned, and execution times per persona.
4. **Lambda** — Powertools structured JSON logging + X-Ray tracing to CloudWatch Logs.

Audit logs: `s3://datalake-audit-{env}` with 5-year retention per SEC Rule 204-2 (prod).

---

## 4. Deployment Guide

### Prerequisites

**Local development:**
- Docker Desktop
- [Kind](https://kind.sigs.k8s.io/), [Tilt](https://tilt.dev/), [Task](https://taskfile.dev/)
- Terraform >= 1.7, kubectl

**AWS deployment:**
- AWS CLI v2 with SSO configured
- Terraform >= 1.7
- S3 backend for Terraform state (`mayadangelou-datalake-tfstate`)

### Local Development (Kind + ArgoCD + Tilt)

The local environment uses Kind for a Kubernetes cluster, ArgoCD for GitOps deployment, and Tilt for the dev loop. Kafka Connect runs via Strimzi, PostgreSQL via StatefulSet, and the producer-api via FastAPI.

```bash
task up                  # Full bootstrap: Kind + ArgoCD + Tilt
task status              # Show all resource statuses
task argocd:password     # Get ArgoCD admin password (UI at http://localhost:8080)
task db:seed             # Seed sample financial data into PostgreSQL
task db:shell            # Interactive psql session
task down                # Tear down everything
```

**What gets deployed locally:**

1. Kind cluster with ArgoCD
2. Strimzi Kafka operator + local Kafka cluster
3. PostgreSQL StatefulSet with trading schema (5 tables)
4. Debezium source connector (CDC from PostgreSQL)
5. Iceberg sink connectors (MNPI + non-MNPI)
6. Producer API (FastAPI with trading simulator)

### AWS Deployment

The AWS infrastructure uses a single root module with `terraform.workspace` (dev | prod) and a config map in `locals.tf` to drive per-environment settings. Feature flags control which modules deploy:

| Feature Flag | Dev | Prod |
|-------------|-----|------|
| `enable_msk` | false | true |
| `enable_aurora` | false | true |
| `enable_msk_connect` | false | true |
| `enable_lambda_producer` | false | true |
| `enable_glue_etl` | true | true |
| `enable_quicksight` | false | true |

```bash
# Initialize
cd terraform/aws
terraform init
terraform workspace select dev   # or prod

# Deploy
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars

# Or via Taskfile
task aws:plan TF_WORKSPACE=prod
task aws:apply TF_WORKSPACE=prod
```

**Prod-only setup steps:**

1. **Build Lambda artifacts:** `./scripts/build_lambda.sh` (creates `.build/trading-simulator.zip` and `.build/trading-simulator-layer.zip`)
2. **Upload connector plugins:** `./scripts/upload-connector-plugins.sh` (downloads Debezium + Iceberg JARs, repackages as ZIPs, uploads to S3)
3. **Initialize Aurora CDC:** `./scripts/init-aurora-cdc.sh` (creates replication slot, publication, seeds 5 tables)
4. **Deploy:** `terraform apply -var-file=prod.tfvars`

### Module Dependency Graph

```
networking
    ├──► streaming (subnet_ids, msk_security_group_id)
    ├──► aurora_postgres (vpc_id, subnet_ids, allowed_security_group_ids)
    └──► data_lake_storage (independent)
             ├──► glue_catalog (bucket IDs)
             ├──► identity_center (bucket ARNs)
             ├──► service_roles (bucket ARNs, KMS key ARNs, cluster ARN)
             │         └──► data_lake_storage (allowed_principal_arns — Glue role added to allowlist)
             ├──► lake_formation (IC group IDs, database names, Glue ETL role ARN)
             ├──► observability (bucket ARNs, account_id)
             ├──► analytics (query_results bucket)
             ├──► glue_etl (Glue role ARN, scripts bucket)
             ├──► msk_connect (MSK ARN, bucket ARNs, Aurora endpoint + secret)
             └──► lambda_producer (subnet_ids, MSK ARN, Aurora ARN + secret)
```

---

## 5. Query Examples

### Finance Analyst

Access: curated + analytics layers, both MNPI and non-MNPI zones.

```sql
-- MNPI curated data (SUCCEEDS)
SELECT COUNT(*) AS total_orders FROM curated_mnpi_prod.order_events;

-- Non-MNPI analytics (SUCCEEDS)
SELECT * FROM analytics_nonmnpi_prod.market_summary LIMIT 5;

-- Raw layer (FAILS — AccessDeniedException)
-- SELECT COUNT(*) FROM raw_mnpi_prod.orders;  -- DENIED
```

### Data Analyst

Access: curated + analytics layers, non-MNPI zone only.

```sql
-- Non-MNPI curated (SUCCEEDS)
SELECT COUNT(*) FROM curated_nonmnpi_prod.market_ticks;

-- MNPI curated (FAILS — AccessDeniedException)
-- SELECT COUNT(*) FROM curated_mnpi_prod.order_events;  -- DENIED
```

### Data Engineer

Access: all layers, all zones, plus direct S3 access.

```sql
-- Raw layer (SUCCEEDS)
SELECT COUNT(*) FROM raw_mnpi_prod.orders;

-- Iceberg time-travel: list snapshots
SELECT * FROM raw_mnpi_prod."orders$snapshots" ORDER BY committed_at DESC;

-- Iceberg time-travel: records per snapshot
SELECT
    s.snapshot_id,
    s.committed_at,
    s.operation,
    s.summary['added-records'] AS added_records,
    s.summary['total-records'] AS total_records
FROM raw_mnpi_prod."orders$snapshots" s
ORDER BY s.committed_at;
```

---

## 6. Trading Simulator

### Production: Lambda Trading Simulator

**Source:** [`scripts/lambda/trading_simulator/`](../scripts/lambda/trading_simulator/)

The production trading simulator is an AWS Lambda function triggered by EventBridge every 1 minute. Each invocation runs one trading cycle:

1. Pick a random instrument (8 tickers: AAPL, MSFT, GOOGL, AMZN, JPM, GS, SPY, QQQ) and account (IDs 1-5)
2. Generate a random order (BUY/SELL, MARKET/LIMIT, random quantity)
3. **INSERT order** into Aurora via RDS Data API
4. Jitter the price (`random.uniform(0.995, 1.005)`)
5. **INSERT trade** into Aurora via RDS Data API
6. **UPDATE order** to FILLED
7. **Produce market data tick** to MSK topic `stream.market-data`
8. **UPSERT position** in Aurora

**Components:**

| File | Purpose |
|------|---------|
| `main.py` | Lambda handler with Powertools Logger + Tracer. Initializes DB/Kafka clients outside handler for warm reuse. |
| `simulator.py` | Trading cycle logic. 8 instruments, 5 accounts, price jitter. |
| `database.py` | RDS Data API wrapper (`boto3 rds-data`). Named parameters with typed values. |
| `producer.py` | MSK Kafka producer with IAM auth (`kafka-python` + `aws-msk-iam-sasl-signer`). Reconnect-on-failure for warm Lambda reuse. |
| `requirements.txt` | `kafka-python`, `aws-msk-iam-sasl-signer-python` (boto3 from runtime, Powertools from managed layer) |

**Data flow:**
- Orders/trades/positions: Lambda → Aurora (INSERT) → Debezium CDC (WAL) → MSK → Iceberg Sink → S3
- Market data: Lambda → MSK (direct produce) → Iceberg Sink → S3
- Orders do NOT dual-write to Kafka. CDC captures all Aurora changes.

**Build:** `./scripts/build_lambda.sh` produces two artifacts in `.build/`:
- `trading-simulator-layer.zip` (~18 MB) — pip dependencies for `manylinux2014_x86_64`
- `trading-simulator.zip` (~8 KB) — Python source files only

### Local Development: Producer API

**Source:** [`producer-api/`](../producer-api/)

The local dev environment uses a FastAPI service with the same trading simulator logic, running as a Kubernetes pod managed by ArgoCD. It connects to local Strimzi Kafka and the Kind-hosted PostgreSQL.

```bash
task test:unit       # Run 28 unit tests
task test:unit:quick # No coverage
```

---

## 7. Glue ETL Pipeline

**Module:** [`modules/glue-etl`](../terraform/aws/modules/glue-etl/) | **Scripts:** [`scripts/glue/`](../scripts/glue/)

Four Glue 4.0 PySpark jobs transform data through the medallion layers. All jobs use `GlueCatalog` with Iceberg table format. MNPI and non-MNPI data flow through separate databases at every layer — the two zones never merge.

### End-to-End Data Lineage

```
 INGESTION                        RAW                      CURATED                    ANALYTICS
─────────────                 ──────────               ─────────────              ───────────────

Lambda → Aurora               raw_mnpi_{env}           curated_mnpi_{env}         analytics_mnpi_{env}
  (orders,trades,positions)     .mnpi_events    ──►      .order_events     ──►      .order_summary
  Debezium CDC → Kafka            (append-only             (deduplicated,            (per-ticker
  → Iceberg Sink → S3              CDC events)              typed, derived)           aggregates)

Lambda → Kafka                raw_nonmnpi_{env}        curated_nonmnpi_{env}      analytics_nonmnpi_{env}
  (market data ticks)           .nonmnpi_events  ──►     .market_ticks      ──►     .market_summary
  → Iceberg Sink → S3            (append-only             (deduplicated,            (per-ticker
                                  stream events)           typed, derived)           aggregates)
```

### Raw Layer (ingestion — no Glue involvement)

MSK Connect Iceberg sinks write directly to S3. Glue ETL does not touch this layer — it only reads from it.

**MNPI raw table** (`raw_mnpi_{env}.mnpi_events`): Append-only CDC events from Debezium capturing every INSERT, UPDATE, and DELETE on the `orders`, `trades`, and `positions` tables in Aurora. Each row is a Kafka message with fields stored as strings by the Iceberg sink connector.

**Non-MNPI raw table** (`raw_nonmnpi_{env}.nonmnpi_events`): Append-only market data ticks produced directly by the Lambda trading simulator, plus CDC events from the `accounts` and `instruments` tables. All fields arrive as strings.

### Raw → Curated Transforms

The curated layer produces clean, typed, deduplicated current-state tables from the raw append-only event stream. Both curated jobs follow the same four-step pattern: **filter → dedup → cast + derive → DQ check**.

#### Job 1: `curated_order_events` (MNPI)

**Source:** `raw_mnpi_{env}.mnpi_events` → **Target:** `curated_mnpi_{env}.order_events`

| Step | Operation | Detail |
|------|-----------|--------|
| Filter | Remove nulls/tombstones | `ticker IS NOT NULL AND ticker != '' AND event_type IS NOT NULL AND event_type != ''` |
| Dedup | `ROW_NUMBER` by `event_id` | Partition by `event_id`, order by `timestamp DESC` — keeps the latest event per ID |
| Cast | String → proper types | `quantity` string → bigint, `timestamp` string → timestamp |
| Derive | Add computed columns | `is_buy` (boolean: `side == 'BUY'`), `event_hour` (truncated timestamp for partitioning) |
| DQ | Fail job if checks fail | `row_count > 0`, `no null event_ids` |

**Output schema:**

| Column | Type | Source |
|--------|------|--------|
| `event_id` | string | passthrough |
| `event_type` | string | passthrough |
| `ticker` | string | passthrough |
| `side` | string | passthrough |
| `quantity` | bigint | cast from string |
| `order_id` | string | passthrough |
| `account_id` | string | passthrough |
| `instrument_id` | string | passthrough |
| `event_timestamp` | timestamp | cast from string |
| `is_buy` | boolean | derived: `side == 'BUY'` |
| `event_hour` | timestamp | derived: `date_trunc('hour', timestamp)` |

#### Job 2: `curated_market_ticks` (Non-MNPI)

**Source:** `raw_nonmnpi_{env}.nonmnpi_events` → **Target:** `curated_nonmnpi_{env}.market_ticks`

| Step | Operation | Detail |
|------|-----------|--------|
| Filter | Remove nulls/tombstones | `ticker IS NOT NULL AND ticker != ''` |
| Dedup | `ROW_NUMBER` by `tick_id` | Partition by `tick_id`, order by `timestamp DESC` — keeps the latest tick per ID |
| Cast | String → proper types | `bid`, `ask`, `last_price` string → double; `timestamp` string → timestamp |
| Derive | Add computed columns | `spread` (double: `ask - bid`), `mid_price` (double: `(ask + bid) / 2`), `tick_hour` (truncated timestamp) |
| DQ | Fail job if checks fail | `row_count > 0`, `no null tickers` |

**Output schema:**

| Column | Type | Source |
|--------|------|--------|
| `tick_id` | string | passthrough |
| `ticker` | string | passthrough |
| `bid` | double | cast from string |
| `ask` | double | cast from string |
| `last_price` | double | cast from string |
| `volume` | string | passthrough |
| `instrument_id` | string | passthrough |
| `tick_timestamp` | timestamp | cast from string |
| `spread` | double | derived: `ask - bid` |
| `mid_price` | double | derived: `(ask + bid) / 2` |
| `tick_hour` | timestamp | derived: `date_trunc('hour', timestamp)` |

### Curated → Analytics Transforms

The analytics layer pre-aggregates curated data into per-ticker summary tables for dashboards and reporting. Both analytics jobs group by `ticker` and produce one row per ticker.

#### Job 3: `analytics_order_summary` (MNPI)

**Source:** `curated_mnpi_{env}.order_events` → **Target:** `analytics_mnpi_{env}.order_summary`

**Output schema (one row per ticker):**

| Column | Type | Aggregation |
|--------|------|-------------|
| `ticker` | string | group key |
| `total_orders` | bigint | `COUNT(*)` |
| `buy_orders` | bigint | `COUNT(WHERE is_buy)` |
| `sell_orders` | bigint | `COUNT(WHERE NOT is_buy)` |
| `total_volume` | bigint | `SUM(quantity)` |
| `avg_order_size` | bigint | `ROUND(AVG(quantity))` |
| `buy_sell_ratio` | double | `buy_orders / sell_orders` (null-safe, >1 = net buying pressure) |
| `first_order_at` | timestamp | `MIN(event_timestamp)` |
| `last_order_at` | timestamp | `MAX(event_timestamp)` |

**DQ check:** `row_count > 0`

#### Job 4: `analytics_market_summary` (Non-MNPI)

**Source:** `curated_nonmnpi_{env}.market_ticks` → **Target:** `analytics_nonmnpi_{env}.market_summary`

**Output schema (one row per ticker):**

| Column | Type | Aggregation |
|--------|------|-------------|
| `ticker` | string | group key |
| `tick_count` | bigint | `COUNT(*)` |
| `total_volume` | bigint | `SUM(volume)` |
| `low_price` | double | `MIN(last_price)` |
| `high_price` | double | `MAX(last_price)` |
| `avg_price` | double | `AVG(last_price)` |
| `avg_spread` | double | `AVG(spread)` |
| `avg_mid_price` | double | `AVG(mid_price)` |
| `spread_pct` | double | `(avg_spread / avg_mid_price) * 100` — liquidity indicator |
| `first_tick_at` | timestamp | `MIN(tick_timestamp)` |
| `last_tick_at` | timestamp | `MAX(tick_timestamp)` |

**DQ check:** `row_count > 0`

### Data Quality Gates

Every job runs inline DQ checks before writing. If any check fails, the job raises `ValueError` and aborts — no corrupt data reaches downstream tables. The `assert_quality()` function logs which checks passed and halts on the first failure.

| Layer | Checks |
|-------|--------|
| Curated | Row count > 0 (source not empty), no null primary keys (event_id / tick_id) |
| Analytics | Row count > 0 (aggregation produced results) |

### Write Strategy

All four jobs use `createOrReplace` — a full-refresh overwrite of the target Iceberg table on each run. This is idempotent: re-running the workflow produces identical results. Iceberg snapshots preserve every write, so the previous state is recoverable via time-travel.

**Trade-off:** Full refresh is simple and correct, but re-processes all data every run. For large datasets, a future optimization would switch to incremental processing with `MERGE INTO` based on watermarks.

### Workflow Orchestration

The `datalake-medallion-{env}` Glue workflow orchestrates the four jobs:

```
ON_DEMAND (dev) / cron every 6h (prod)
    │
    ├──► curated_order_events  ──┐
    │                            ├──► CONDITIONAL (both SUCCEEDED)
    └──► curated_market_ticks  ──┘         │
                                           ├──► analytics_order_summary
                                           └──► analytics_market_summary
```

The two curated jobs run in parallel. Both must succeed before the two analytics jobs start (also in parallel). If either curated job fails, the conditional trigger does not fire and analytics jobs do not run.

### Glue + Iceberg Configuration

Scripts are stored in `s3://{query-results-bucket}/glue-scripts/` (no DENY policy on this bucket). Each job receives `--environment` and `--iceberg-warehouse` as job arguments.

**Critical pattern for Glue 4.0 + Iceberg + GlueCatalog:**

1. `--datalake-formats=iceberg` only adds JARs — you must manually register the named catalog via `SparkSession.builder.config()`
2. Use `spark.table("glue_catalog.db.table")` for reads — NOT `spark.read.format("iceberg").load()` (causes `None.get` error)
3. Use `df.writeTo("glue_catalog.db.table").using("iceberg").createOrReplace()` for writes
4. `GlueCatalog` requires a non-null `warehouse` path at init (passed via `--iceberg-warehouse` job argument)

| Setting | Dev | Prod |
|---------|-----|------|
| Workers per job | 2 (G.1X) | 5 (G.1X) |
| Schedule | ON_DEMAND | `cron(0 */6 * * ? *)` |

---

## 8. Production Infrastructure

### MSK

| Setting | Dev | Prod |
|---------|-----|------|
| Instance type | `kafka.t3.small` | `kafka.m5.large` |
| Broker count | 1 | 2 (one per AZ) |
| Replication factor | 1 | 2 |
| Auth | IAM | IAM |
| Encryption | TLS in-transit | TLS in-transit |

### Aurora PostgreSQL

| Setting | Prod |
|---------|------|
| Engine | Aurora PostgreSQL 15 |
| Instance class | `db.r6g.large` |
| Instance count | 2 (writer + reader) |
| CDC | Logical replication enabled (`rds.logical_replication = 1`) |
| SSL | Enforced (PG 15 default) |
| Secrets | JSON format in Secrets Manager (`{"username":"...","password":"..."}`) |

### MSK Connect Connectors

Three managed connectors (no self-hosted Kafka Connect in prod):

| Connector | Type | Purpose |
|-----------|------|---------|
| `debezium-source` | Debezium PostgreSQL | CDC from Aurora → 5 MSK topics |
| `iceberg-sink-mnpi` | Iceberg S3 Sink | 3 MNPI topics → S3 MNPI bucket |
| `iceberg-sink-nonmnpi` | Iceberg S3 Sink | 3 non-MNPI topics → S3 non-MNPI bucket |

**Plugin format:** MSK Connect requires real ZIP files. The `upload-connector-plugins.sh` script downloads tar.gz archives and repackages them as ZIP before upload.

### Networking

| Component | Configuration |
|-----------|--------------|
| VPC | Single VPC with DNS support |
| Subnets | 2 private (workloads), 1 public (NAT Gateway only) |
| NAT Gateway | Single NAT for Lambda outbound to AWS endpoints |
| S3 Gateway Endpoint | Iceberg writes stay within AWS network |
| STS Interface Endpoint | MSK IAM token generation without NAT |
| Security Groups | MSK (port 9098 from Lambda SG), Lambda (egress to MSK + Aurora + all via NAT), Aurora (port 5432 from Lambda + MSK Connect SGs) |

### Retention

| Data | Retention |
|------|-----------|
| Audit logs | 5 years (SEC Rule 204-2) |
| Raw S3 data | Transition to Standard-IA after 90 days |
| Kafka topics | 7 days default |
| CloudWatch logs | Configurable per log group |
| Iceberg snapshots | Indefinite (audit trail) |

### Monitoring

| Component | Monitoring |
|-----------|-----------|
| Lambda | Powertools structured JSON logs + X-Ray tracing in CloudWatch |
| MSK | CloudWatch broker metrics (BytesInPerSec, UnderReplicatedPartitions) |
| MSK Connect | Connector status (RUNNING/FAILED), consumer lag |
| Glue ETL | Workflow run status, job metrics, continuous CloudWatch logs |
| S3 | CloudTrail data events on both data lake buckets |
| Athena | Workgroup metrics (query count, bytes scanned, execution time) |
| QuickSight | Data source connected to Athena `data-engineers` workgroup |

---

## 9. Decision Log

### 1. Fully Serverless Architecture (No EKS)

**Choice:** Lambda + MSK Connect + managed services. No EKS.

**Rationale:** EKS adds operational overhead (node management, OIDC provider, IRSA, ArgoCD deployment) for workloads that are event-driven and intermittent. Lambda handles the trading simulator (1 invocation/min). MSK Connect manages Kafka Connect connectors as a fully managed service. Glue ETL handles transforms on a schedule.

**Trade-off:** Less flexibility than EKS for arbitrary workloads, but eliminates all compute management for this use case.

### 2. MSK Provisioned over MSK Serverless

**Choice:** MSK Provisioned (`kafka.t3.small` dev, `kafka.m5.large` prod)

**Rationale:** Debezium requires custom topic-level configuration. MSK Serverless does not support custom topic settings, making it incompatible with Debezium CDC.

### 3. MSK Connect over Strimzi (Production)

**Choice:** AWS MSK Connect for production Kafka Connect connectors. Strimzi remains for local development.

**Rationale:** MSK Connect is serverless — no pods or nodes to manage. Connectors auto-scale and auto-recover. The trade-off is vendor lock-in, but production simplicity outweighs portability for managed connectors. Local dev retains Strimzi for the same connector configs in a Kind cluster.

### 4. Apache Iceberg over Delta Lake

**Choice:** Apache Iceberg as the table format.

**Rationale:** Iceberg has native Athena support without additional configuration. It provides ACID transactions for CDC writes, time-travel via snapshot queries for audit compliance, and schema evolution for CDC DDL changes.

### 5. LF-Tags over Database-Level Grants

**Choice:** Lake Formation LF-Tags (attribute-based access control).

**Rationale:** Two tag keys (`sensitivity`, `layer`) with AND-logic create 6 access combinations from 3 grant definitions. New tables automatically inherit tags. No Terraform changes needed when tables are added.

### 6. Topic-per-Table MNPI Routing

**Choice:** Structural MNPI routing via dedicated topic subscriptions per sink connector.

**Rationale:** Classification is determined by which topics a connector subscribes to, not by runtime logic. This is auditable (version-controlled config), simple (no classification code), and secure (no code path where MNPI data could reach a non-MNPI sink).

### 7. RDS Data API over Direct PostgreSQL Connection

**Choice:** Lambda uses the RDS Data API (`rds-data:ExecuteStatement`) instead of a direct PostgreSQL connection via `psycopg2`.

**Rationale:** The RDS Data API is HTTPS-based and does not require VPC routing to Aurora. Lambda only needs VPC placement for MSK access (port 9098). This eliminates the need for connection pooling (RDS Proxy) and simplifies IAM — Secrets Manager credentials are used by the Data API service, not by Lambda directly.

### 8. IAM Identity Center over Direct IAM Roles

**Choice:** IC groups and permission sets for human identity management.

**Rationale:** Centralized human identity management with federation support, automatic SSO role provisioning, and separation from machine identities. Lake Formation grants use IC group ARN principals via trusted identity propagation.

### 9. Append-Only Raw Layer with Glue ETL Transforms

**Choice:** Raw layer is append-only Iceberg via MSK Connect sinks. Glue ETL PySpark jobs transform raw → curated → analytics.

**Rationale:** Preserves the full CDC event history for audit. Every change from Debezium is stored immutably. The curated layer produces clean current-state tables. The analytics layer provides pre-aggregated reporting. All transforms are repeatable and scheduled.

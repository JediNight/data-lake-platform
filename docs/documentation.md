# Data Lake Platform Documentation

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Model](#2-data-model)
3. [Security Architecture](#3-security-architecture)
4. [Deployment Guide](#4-deployment-guide)
5. [Query Examples](#5-query-examples)
6. [Producer API](#6-producer-api)
7. [Production Considerations](#7-production-considerations)
8. [Decision Log](#8-decision-log)

---

## 1. Architecture Overview

This platform is a secure, auditable, and scalable AWS-based Data Lake for an asset management firm. It ingests data from an RDBMS via Change Data Capture (CDC) and Kafka streaming sources, stores it in a medallion architecture (raw, curated, analytics) with strict MNPI/non-MNPI isolation, and provides role-based query access through Amazon Athena with Lake Formation enforcement.

### High-Level Diagram

See [`docs/architecture-diagram.png`](./architecture-diagram.png) for the full visual diagram.

### Kafka-Centric Pipeline

The platform uses a **Kafka-centric architecture** where all data flows through Amazon MSK as a unified event backbone. This means CDC events from PostgreSQL (via Debezium) and streaming events from external producers all converge into MSK topics before being written to S3 as Apache Iceberg tables.

```
PostgreSQL (CDC) ──► Debezium (Strimzi) ──► MSK Topics ──► Iceberg Sink ──► S3 (Iceberg)
                                                                                   │
External Kafka Producers ──────────────────► MSK Topics ──► Iceberg Sink ──► S3 (Iceberg)
                                                                                   │
                                                                                   ▼
                                                                         Glue Catalog (6 DBs)
                                                                                   │
                                                                                   ▼
                                                                      Lake Formation (LF-Tags)
                                                                                   │
                                                                                   ▼
                                                                      Athena (3 Workgroups)
```

**Medallion layers:**

| Layer | Purpose | Write Mode | Storage |
|-------|---------|------------|---------|
| **Raw** | Full CDC event history (append-only) | Append-only Iceberg tables | Partitioned by `days(source_timestamp)` |
| **Curated** | Current-state tables via `MERGE INTO` | Upsert (Athena SQL) | Partitioned by `days(updated_at)` |
| **Analytics** | Pre-aggregated reporting tables | CTAS (Athena SQL) | Partitioned by `months(report_date)` |

Each layer is replicated across MNPI and non-MNPI zones, yielding 6 Glue Catalog databases: `raw_mnpi`, `raw_nonmnpi`, `curated_mnpi`, `curated_nonmnpi`, `analytics_mnpi`, `analytics_nonmnpi`.

### Project Structure

```
data-lake-platform/
├── Taskfile.yml                        # Lifecycle tasks (up, down, status, aws:*)
├── Tiltfile                            # Local dev loop (Kind + ArgoCD + Tilt)
├── kind-config.yaml                    # Kind cluster: 1 CP + 1 worker
├── appset-management.yaml              # ArgoCD root ApplicationSet
├── .sops.yaml                          # Age encryption config
│
├── terraform/
│   ├── local/                          # Kind + ArgoCD bootstrap (Terraform)
│   └── aws/
│       ├── modules/
│       │   ├── networking/             # VPC, subnets, S3 gateway, security groups
│       │   ├── data-lake-storage/      # S3 buckets, KMS keys, bucket policies
│       │   ├── streaming/              # MSK Provisioned cluster
│       │   ├── glue-catalog/           # 6 Glue databases, schema registry
│       │   ├── iam-personas/           # 3 persona roles + service roles
│       │   ├── lake-formation/         # LF-Tags, grants, S3 registrations
│       │   ├── analytics/              # Athena workgroups, named queries
│       │   └── observability/          # CloudTrail, audit bucket, QuickSight
│       └── environments/
│           ├── dev/                    # kafka.t3.small x1, 90-day retention
│           └── prod/                   # kafka.m5.large x3, 5-year retention
│
├── strimzi/                            # Kafka Connect (Strimzi CRDs)
│   ├── base/
│   │   ├── kafka-connect.yaml          # KafkaConnect cluster image + plugins
│   │   ├── debezium-source.yaml        # Debezium PostgreSQL source connector
│   │   ├── iceberg-sink-mnpi.yaml      # MNPI Iceberg sink connector
│   │   └── iceberg-sink-nonmnpi.yaml   # Non-MNPI Iceberg sink connector
│   └── overlays/localdev/              # Local dev Kustomize patches
│
├── sample-postgres/                    # Source RDBMS for CDC demo
│   └── base/
│       ├── statefulset.yaml            # PostgreSQL StatefulSet
│       └── init-schema.sql             # CREATE TABLE for 5 source tables
│
├── producer-api/                       # FastAPI producer service with trading simulator
│
├── scripts/
│   ├── 00_seed/seed-data.sql           # Sample financial data
│   ├── 01_curated/                     # MERGE INTO transforms (5 tables)
│   ├── 02_analytics/                   # CTAS aggregation queries (2 tables)
│   └── validation/                     # Access validation + Iceberg time-travel
│
└── docs/
    ├── plans/                          # Design doc
    ├── architecture-diagram.png        # Visual architecture diagram
    └── documentation.md                # This file
```

---

## 2. Data Model

### Source Tables (PostgreSQL CDC)

The platform captures 5 tables from a PostgreSQL trading database via Debezium CDC. Tables are classified as MNPI or non-MNPI at the structural level (topic-per-table), not at the row level.

**Schema definition:** [`sample-postgres/base/init-schema.sql`](../sample-postgres/base/init-schema.sql)

#### MNPI Tables

| Table | Key Fields | MNPI Rationale |
|-------|-----------|----------------|
| **orders** | `order_id`, `account_id`, `instrument_id`, `side`, `quantity`, `order_type`, `status`, `disclosure_status` | Contains non-public trading intent: which accounts are buying/selling what, in what quantities, before execution. This is classic insider information under SEC regulations. |
| **trades** | `trade_id`, `order_id`, `instrument_id`, `quantity`, `price`, `execution_venue`, `settlement_date`, `disclosure_status` | Contains non-public execution data: actual fill prices, quantities, and venues before public disclosure. Trade data reveals the firm's market activity. |
| **positions** | `position_id`, `account_id`, `instrument_id`, `quantity`, `market_value`, `position_date` | Contains non-public holdings: the firm's aggregate exposure per instrument per account. Position data reveals portfolio composition before regulatory filings (13F). |

#### Non-MNPI Tables

| Table | Key Fields | Non-MNPI Rationale |
|-------|-----------|-------------------|
| **accounts** | `account_id`, `account_name`, `account_type`, `status` | Reference/metadata only. Account names and types do not reveal trading activity or intent. This is internal organizational data. |
| **instruments** | `instrument_id`, `ticker`, `cusip`, `isin`, `name`, `instrument_type`, `exchange` | Publicly available reference data. Tickers, CUSIPs, ISINs, and exchange listings are published by exchanges and data vendors. |

### CDC Topics (auto-created by Debezium)

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
| `stream.order-events` | MNPI | Trading platform producers |
| `stream.market-data` | Non-MNPI | Market data feed producers |
| `stream.order-events.dlq` | MNPI | Failed order events |
| `stream.market-data.dlq` | Non-MNPI | Failed market data events |

### MNPI Routing

MNPI classification is **structural** (topic-per-table), not runtime per-row:

- **MNPI sink** subscribes to: `cdc.trading.orders`, `cdc.trading.trades`, `cdc.trading.positions`, `stream.order-events`
- **Non-MNPI sink** subscribes to: `cdc.trading.accounts`, `cdc.trading.instruments`, `stream.market-data`

**Known limitation:** All trades remain in the MNPI zone permanently, even after public disclosure. The `disclosure_status` field provides temporal metadata for analytics within the MNPI zone. A production enhancement would add a scheduled job to copy disclosed records to the non-MNPI curated layer.

### Iceberg Table Design

| Layer | Partition Spec | Write Mode |
|-------|---------------|------------|
| Raw | `days(source_timestamp)` | Append-only (`upsert-mode-enabled=false`) |
| Curated | `days(updated_at)` | MERGE INTO (current state from raw CDC log) |
| Analytics | `months(report_date)` | CTAS (full rebuild from curated) |

The raw layer is **append-only** by design. This preserves the complete CDC event history (create, update, delete operations) and provides a full audit trail via Iceberg snapshots. The curated layer produces current-state tables by running `MERGE INTO` queries that deduplicate the raw CDC event stream.

---

## 3. Security Architecture

### MNPI Isolation via Separate S3 Buckets and KMS Keys

**Module:** [`terraform/aws/modules/data-lake-storage/main.tf`](../terraform/aws/modules/data-lake-storage/main.tf)

MNPI and non-MNPI data are physically isolated into separate S3 buckets with independent KMS Customer Managed Keys (CMKs):

| Bucket | KMS Key | Purpose |
|--------|---------|---------|
| `datalake-mnpi-{env}` | `alias/datalake-mnpi-{env}` | Orders, trades, positions (MNPI data) |
| `datalake-nonmnpi-{env}` | `alias/datalake-nonmnpi-{env}` | Accounts, instruments (non-MNPI data) |
| `datalake-audit-{env}` | Non-MNPI CMK | CloudTrail audit logs |
| `datalake-query-results-{env}` | Non-MNPI CMK | Athena query results |

Both data lake buckets have versioning enabled and all public access blocked. KMS key rotation is enabled on both CMKs.

### Lake Formation LF-Tags for Attribute-Based Access Control

**Module:** [`terraform/aws/modules/lake-formation/main.tf`](../terraform/aws/modules/lake-formation/main.tf)

Two LF-Tag keys control access across all 6 Glue databases:

| Tag Key | Values | Purpose |
|---------|--------|---------|
| `sensitivity` | `mnpi`, `non-mnpi` | Controls which data zone a principal can access |
| `layer` | `raw`, `curated`, `analytics` | Controls which medallion layer a principal can access |

Tag assignments to databases:

| Database | sensitivity | layer |
|----------|-------------|-------|
| `raw_mnpi` | mnpi | raw |
| `raw_nonmnpi` | non-mnpi | raw |
| `curated_mnpi` | mnpi | curated |
| `curated_nonmnpi` | non-mnpi | curated |
| `analytics_mnpi` | mnpi | analytics |
| `analytics_nonmnpi` | non-mnpi | analytics |

New tables added to any database **automatically inherit** its LF-Tags, so grants apply without Terraform changes.

The default `IAMAllowedPrincipals` is removed from Lake Formation settings, forcing all data access through LF grants rather than plain IAM.

### S3 Bucket Policies for LF Bypass Prevention

Both data lake buckets carry a bucket policy that **DENIES** `s3:GetObject` and `s3:PutObject` for all principals except:

1. **Lake Formation service-linked role** -- vends temporary credentials for Athena queries
2. **Kafka Connect IRSA role** -- direct S3 write for Iceberg sink connectors
3. **Data Engineer role** -- exercise requires direct S3 access for ETL
4. **Break-glass admin role**

Without this policy, any IAM principal with `s3:GetObject` could read data directly from S3, bypassing Lake Formation column/row-level security.

### IAM Personas and Access Levels

**Module:** [`terraform/aws/modules/iam-personas/main.tf`](../terraform/aws/modules/iam-personas/main.tf)

| Persona | LF-Tag Grant | Athena Workgroup | Direct S3 |
|---------|-------------|-----------------|-----------|
| **Finance Analyst** | `SELECT` where `sensitivity IN (mnpi, non-mnpi)` AND `layer IN (curated, analytics)` | `finance-analysts` (scan-limited) | No |
| **Data Analyst** | `SELECT` where `sensitivity = non-mnpi` AND `layer IN (curated, analytics)` | `data-analysts` (scan-limited) | No |
| **Data Engineer** | `ALL` where `sensitivity IN (mnpi, non-mnpi)` AND `layer IN (raw, curated, analytics)` + `DATA_LOCATION_ACCESS` | `data-engineers` (unlimited) | Yes (exempted from deny policy) |

### Endpoint Security

| Connection | Security Mechanism |
|------------|-------------------|
| Debezium to PostgreSQL | SSL mode `require` in JDBC URL |
| Debezium to MSK | IAM authentication + TLS in-transit |
| Iceberg Sink to MSK | IAM authentication + TLS in-transit |
| Iceberg Sink to S3 | IRSA scoped to target bucket ARN |
| Athena to S3 | Lake Formation temporary scoped credentials |
| S3 data at rest | KMS-SSE encryption, separate CMK per zone |
| EKS to MSK networking | MSK in private subnets, SG allows port 9098 from EKS node SG only |
| EKS to S3 networking | S3 VPC gateway endpoint (traffic stays within AWS network) |

**Networking module:** [`terraform/aws/modules/networking/main.tf`](../terraform/aws/modules/networking/main.tf) -- private subnets only, no internet gateway. The S3 gateway endpoint routes Iceberg writes directly to S3 without traversing the public internet.

### Exactly-Once Semantics for Financial CDC

Financial CDC data (orders, trades, positions) requires exactly-once delivery because duplicates in trade or position data produce incorrect reporting and compliance violations.

Configuration (from [`strimzi/base/iceberg-sink-mnpi.yaml`](../strimzi/base/iceberg-sink-mnpi.yaml)):

- **Transactional producer**: Iceberg Kafka Connect Sink is configured with a transactional producer
- **Consumer isolation**: `isolation.level=read_committed` ensures consumers only see committed messages
- **Append-only raw layer**: `iceberg.tables.upsert-mode-enabled=false` prevents partial writes from corrupting state

### CloudTrail S3 Data Events for Audit Trail

**Module:** [`terraform/aws/modules/observability/main.tf`](../terraform/aws/modules/observability/main.tf)

Three-tier audit coverage:

1. **CloudTrail** -- S3 data events enabled on both MNPI and non-MNPI buckets. Every `ReadObject` and `WriteObject` is logged with principal, action, timestamp, and source IP. Log file validation is enabled for tamper detection.
2. **Lake Formation** -- Audit logs capture all LF grant evaluations (who tried to access what, and whether it was allowed or denied).
3. **Athena** -- Workgroup-level CloudWatch metrics track query counts, scanned bytes, and execution times per persona.

Audit logs are stored in `s3://datalake-audit-{env}` with a Glue table registered for Athena querying. A CloudWatch log group receives real-time trail events for alerting.

---

## 4. Deployment Guide

### Prerequisites

**Shared:**
- Terraform >= 1.5
- kubectl
- Git

**Local development additionally requires:**
- [Kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker)
- [Tilt](https://tilt.dev/)
- [Task](https://taskfile.dev/) (task runner)
- Docker Desktop running

**AWS deployment additionally requires:**
- AWS CLI configured with appropriate credentials
- An EKS cluster with OIDC provider (for IRSA)
- An S3 backend for Terraform state

### Local Development (Kind + ArgoCD + Tilt)

The local environment uses Kind for a single-node Kubernetes cluster, ArgoCD for GitOps-driven deployment, and Tilt for the inner dev loop. Configuration files:

- [`kind-config.yaml`](../kind-config.yaml) -- 1 control plane + 1 worker node
- [`terraform/local/main.tf`](../terraform/local/main.tf) -- Terraform bootstrap for Kind + ArgoCD
- [`Tiltfile`](../Tiltfile) -- Dev loop file watchers and utility resources
- [`Taskfile.yml`](../Taskfile.yml) -- Lifecycle commands

**Quick start:**

```bash
# Full bootstrap: Kind cluster + ArgoCD + Tilt dev loop
task up

# Or step-by-step:
task infra          # Bootstrap Kind cluster + ArgoCD via Terraform
tilt up             # Start Tilt dev loop (watches strimzi/ and sample-postgres/)

# Check status
task status         # Show all resource statuses across namespaces

# Access ArgoCD UI
task argocd:password   # Get admin password
# Then open http://localhost:8080

# Seed sample data
task db:seed        # Load sample financial data into PostgreSQL

# Open psql shell
task db:shell       # Interactive psql session to trading database

# Tear down
task down           # Destroy everything (Tilt + Terraform)
```

**What gets deployed locally:**

1. Kind cluster with ArgoCD
2. ArgoCD ApplicationSets watch `strimzi/` and `sample-postgres/`
3. PostgreSQL StatefulSet with trading schema (5 tables)
4. Strimzi Kafka operator + local Kafka cluster
5. Debezium source connector (CDC from PostgreSQL)
6. Iceberg sink connectors (MNPI + non-MNPI)

### AWS Deployment

The AWS infrastructure is managed through 8 Terraform modules composed in environment-specific root modules.

**Configuration files:**
- [`terraform/aws/environments/dev/terraform.tfvars`](../terraform/aws/environments/dev/terraform.tfvars) -- Dev settings
- [`terraform/aws/environments/prod/terraform.tfvars`](../terraform/aws/environments/prod/terraform.tfvars) -- Prod settings

```bash
# Initialize Terraform modules
task aws:init

# Preview changes
task aws:plan

# Apply infrastructure
task aws:apply

# Destroy (dev only)
task aws:destroy
```

**Module dependency order** (handled automatically by Terraform):

```
networking
    └──► streaming (needs subnet_ids, msk_security_group_id)
    └──► data_lake_storage (independent)
             └──► glue_catalog (needs bucket IDs)
             └──► iam_personas (needs bucket ARNs, cluster ARN)
                      └──► lake_formation (needs role ARNs, database names)
             └──► observability (needs bucket ARNs)
             └──► analytics (needs query results bucket)
```

---

## 5. Query Examples

**Validation scripts:** [`scripts/validation/access_validation.sql`](../scripts/validation/access_validation.sql)

### Finance Analyst

The finance analyst has access to **curated and analytics layers** across **both MNPI and non-MNPI zones**. They cannot access the raw layer.

```sql
-- Query MNPI curated data (SUCCEEDS)
SELECT COUNT(*) AS total_orders FROM curated_mnpi.orders;
SELECT COUNT(*) AS total_trades FROM curated_mnpi.trades;
SELECT COUNT(*) AS total_positions FROM curated_mnpi.positions;

-- Query non-MNPI curated data (SUCCEEDS)
SELECT COUNT(*) AS total_instruments FROM curated_nonmnpi.instruments;
SELECT COUNT(*) AS total_accounts FROM curated_nonmnpi.accounts;

-- Query MNPI analytics (SUCCEEDS)
SELECT * FROM analytics_mnpi.daily_trade_summary LIMIT 5;
SELECT * FROM analytics_mnpi.position_report LIMIT 5;

-- Query raw layer (FAILS -- AccessDeniedException)
-- SELECT COUNT(*) FROM raw_mnpi.orders;  -- DENIED
```

### Data Analyst

The data analyst has access to **curated and analytics layers** in the **non-MNPI zone only**. All MNPI queries are denied by Lake Formation.

```sql
-- Query non-MNPI curated (SUCCEEDS)
SELECT COUNT(*) AS total_accounts FROM curated_nonmnpi.accounts;
SELECT COUNT(*) AS total_instruments FROM curated_nonmnpi.instruments;

-- Query MNPI curated (FAILS -- AccessDeniedException)
-- SELECT COUNT(*) FROM curated_mnpi.orders;     -- DENIED
-- SELECT COUNT(*) FROM curated_mnpi.trades;      -- DENIED
-- SELECT COUNT(*) FROM curated_mnpi.positions;   -- DENIED

-- Query MNPI analytics (FAILS -- AccessDeniedException)
-- SELECT * FROM analytics_mnpi.daily_trade_summary LIMIT 1;  -- DENIED
```

### Data Engineer

The data engineer has **full access to all layers and all zones**, including the raw layer and direct S3 access.

```sql
-- Query raw layer (SUCCEEDS -- data engineer only)
SELECT COUNT(*) AS raw_order_events FROM raw_mnpi.orders;
SELECT COUNT(*) AS raw_trade_events FROM raw_mnpi.trades;
SELECT COUNT(*) AS raw_position_events FROM raw_mnpi.positions;
SELECT COUNT(*) AS raw_instrument_events FROM raw_nonmnpi.instruments;
SELECT COUNT(*) AS raw_account_events FROM raw_nonmnpi.accounts;

-- Query curated layer (SUCCEEDS)
SELECT COUNT(*) AS curated_orders FROM curated_mnpi.orders;
SELECT COUNT(*) AS curated_instruments FROM curated_nonmnpi.instruments;

-- Query analytics layer (SUCCEEDS)
SELECT * FROM analytics_mnpi.daily_trade_summary LIMIT 5;

-- Iceberg time-travel: list snapshots (data engineer raw layer access)
SELECT * FROM raw_mnpi."orders$snapshots" ORDER BY committed_at DESC;

-- Iceberg time-travel: count events per snapshot
SELECT
    s.snapshot_id,
    s.committed_at,
    s.operation,
    s.summary['added-records'] AS added_records,
    s.summary['total-records'] AS total_records
FROM raw_mnpi."orders$snapshots" s
ORDER BY s.committed_at;
```

See also [`scripts/validation/iceberg_time_travel.sql`](../scripts/validation/iceberg_time_travel.sql) for additional Iceberg snapshot and time-travel query examples.

---

## 6. Producer API

The **Producer API** is a FastAPI service that exercises both ingestion paths of the data lake:

1. **CDC path** -- INSERTs rows into the PostgreSQL trading database, which Debezium captures and streams through MSK to the Iceberg raw layer.
2. **Streaming path** -- Produces events directly to MSK Kafka topics (`stream.order-events` and `stream.market-data`), bypassing the database entirely.

The service includes a built-in **trading simulator** that generates correlated order and market data activity, providing a realistic end-to-end data flow for testing and demonstration.

### REST Endpoints

| Method | Path | Description | Ingestion Path |
|--------|------|-------------|----------------|
| `POST` | `/api/v1/orders` | Submit a trading order | CDC (PostgreSQL INSERT) + Streaming (Kafka produce to `stream.order-events`) |
| `POST` | `/api/v1/market-data` | Submit a market data tick | Streaming only (Kafka produce to `stream.market-data`) |
| `GET` | `/health` | Health check | N/A |

### Manual Testing with curl

```bash
# Submit an order (triggers CDC + streaming)
curl -X POST http://localhost:8000/api/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"account_id": 1, "instrument_id": 1, "ticker": "AAPL", "side": "BUY", "quantity": 100, "order_type": "MARKET"}'

# Submit market data tick (streaming only)
curl -X POST http://localhost:8000/api/v1/market-data \
  -H "Content-Type: application/json" \
  -d '{"tick_id": "test-001", "instrument_id": 1, "ticker": "AAPL", "bid": 178.40, "ask": 178.60, "last_price": 178.50, "volume": 1000, "timestamp": "2026-02-28T12:00:00Z"}'
```

### Simulation Mode

The built-in simulator is enabled via the `SIMULATION_ENABLED=true` environment variable. When active, it generates correlated trading cycles every 5 seconds:

- Market data ticks for configured instruments
- Orders that reference the latest market prices
- Realistic bid/ask spreads and volume patterns

This provides a continuous stream of data through both the CDC and streaming ingestion paths without manual intervention.

### Viewing Logs

```bash
kubectl -n data logs -l app=producer-api -f
```

---

## 7. Production Considerations

The current implementation is sized for development and demonstration. The following changes would be necessary for a production deployment.

### MSK Sizing

| Setting | Dev | Production |
|---------|-----|------------|
| Instance type | `kafka.t3.small` | `kafka.m5.large` |
| Broker count | 1 | 3 (one per AZ) |
| Replication factor | 1 | 3 |
| `min.insync.replicas` | 1 | 2 |
| EBS volume | Default | 1 TB+ with provisioned throughput |

Production values are already configured in [`terraform/aws/environments/prod/terraform.tfvars`](../terraform/aws/environments/prod/terraform.tfvars).

### dbt for Transform Orchestration

The curated layer currently uses manual SQL scripts in [`scripts/01_curated/`](../scripts/01_curated/) and [`scripts/02_analytics/`](../scripts/02_analytics/). In production, these would be replaced with **dbt (data build tool)** for:

- Dependency-aware DAG execution (curated before analytics)
- Incremental materialization (process only new CDC events)
- Data quality tests (schema tests, uniqueness, referential integrity)
- Documentation generation and lineage tracking
- Scheduled runs via dbt Cloud or Airflow

### Multi-AZ Deployment

- MSK brokers distributed across 3 AZs (already configured in prod tfvars)
- EKS node groups across multiple AZs
- S3 is inherently multi-AZ
- Kafka Connect tasks rebalance automatically on broker failure

### Retention

- **Audit logs**: 5 years per SEC Rule 204-2 (`audit_retention_days = 1825` in prod)
- **Raw layer**: Transition to S3 Standard-IA after 90 days (`raw_ia_transition_days = 90` in prod)
- **Kafka topics**: 7 days default retention (`log.retention.hours = 168`)
- **Iceberg snapshots**: Retain indefinitely for audit trail; configure snapshot expiry for storage management

### Monitoring

| Component | Monitoring |
|-----------|-----------|
| MSK | CloudWatch broker metrics (BytesInPerSec, BytesOutPerSec, UnderReplicatedPartitions), JMX + Node exporter for Prometheus |
| Kafka Connect | Connector status (RUNNING/FAILED/PAUSED), task error rates, consumer lag |
| S3 | CloudTrail data events, bucket metrics (object count, storage size) |
| Athena | Workgroup CloudWatch metrics (query count, bytes scanned, execution time) |
| CloudTrail | CloudWatch Logs for real-time alerting on access anomalies |
| Lake Formation | Audit logs for grant evaluation failures (potential access violations) |

**CloudWatch alarms to configure:**

- MSK: `UnderReplicatedPartitions > 0` for 5 minutes
- MSK: `OfflinePartitionsCount > 0`
- Kafka Connect: connector state != RUNNING
- Athena: bytes scanned per query exceeding threshold
- CloudTrail: unauthorized S3 access attempts (metric filter on DENIED events)

### CI/CD

| Layer | Tool | Purpose |
|-------|------|---------|
| Infrastructure | Terraform Cloud or GitHub Actions | Plan on PR, apply on merge to main |
| Kubernetes manifests | ArgoCD | GitOps sync from repository to cluster |
| Container images | ArgoCD Image Updater | Auto-detect new images, update manifests |
| SQL transforms | dbt Cloud or Airflow | Scheduled curated/analytics rebuilds |
| Validation | GitHub Actions | `terraform validate`, `terraform fmt`, SQL linting |

---

## 8. Decision Log

### 1. MSK Provisioned over MSK Serverless

**Choice:** MSK Provisioned (`kafka.t3.small` dev, `kafka.m5.large` prod)

**Rationale:** Debezium requires per-topic configuration for its internal schema history topic (`debezium-schema-history`). MSK Serverless does not support custom topic-level configuration, making it incompatible with Debezium CDC. MSK Provisioned provides full control over broker settings including `auto.create.topics.enable`, replication factor, and retention.

**Trade-off:** Higher operational overhead vs. Serverless, but necessary for CDC compatibility.

### 2. Strimzi over MSK Connect

**Choice:** Strimzi Operator on EKS for Kafka Connect management

**Rationale:** Strimzi is Kubernetes-native, managing connectors as `KafkaConnect` and `KafkaConnector` CRDs. This enables GitOps deployment via ArgoCD, version-controlled connector configurations, and portability across environments (local Kind cluster uses the same manifests as EKS). MSK Connect is an AWS-managed service that would lock connector management into the AWS console/API.

**Trade-off:** Requires running Kafka Connect pods on EKS (compute cost) vs. serverless MSK Connect, but gains portability and declarative management.

### 3. Apache Iceberg over Delta Lake

**Choice:** Apache Iceberg as the table format

**Rationale:** Iceberg is an open standard with native Athena support (no additional configuration). It provides ACID transactions for reliable CDC writes, time-travel via snapshot queries for audit compliance, and schema evolution for handling CDC source DDL changes. Athena's Iceberg integration supports `MERGE INTO` for curated layer upserts and `FOR SYSTEM_VERSION AS OF` for time-travel queries.

**Trade-off:** Delta Lake has stronger Spark ecosystem integration, but Iceberg's Athena-native support eliminates the need for an EMR/Spark cluster.

### 4. LF-Tags over Database-Level Grants

**Choice:** Lake Formation LF-Tags (attribute-based access control)

**Rationale:** LF-Tags provide scalable, automatic inheritance. When a new table is created in a tagged database, it automatically inherits the database's tags and all associated grants apply without any Terraform changes. Database-level grants would require explicit per-table grants for every new table, creating operational overhead and risk of missed permissions.

**Implementation:** Two tag keys (`sensitivity`, `layer`) with AND-logic expressions create a matrix of 6 access combinations from just 3 grant definitions.

### 5. Topic-per-Table MNPI Routing over SMT-Based Classification

**Choice:** Structural MNPI routing via dedicated topic subscriptions per sink connector

**Rationale:** The MNPI sink subscribes to `cdc.trading.orders,cdc.trading.trades,cdc.trading.positions,stream.order-events` while the non-MNPI sink subscribes to `cdc.trading.accounts,cdc.trading.instruments,stream.market-data`. Classification is determined by which topics a connector subscribes to, not by runtime Single Message Transforms (SMTs) inspecting row content.

**Benefits:**
- **Auditable**: Topic subscriptions are declared in version-controlled YAML files
- **Simple**: No runtime classification logic that could misclassify data
- **Secure**: No code path where MNPI data could accidentally flow to a non-MNPI sink
- **Performant**: No per-record classification overhead

**Trade-off:** Less flexible than per-row classification. All records in a topic share the same classification. The `disclosure_status` field handles temporal classification within the MNPI zone.

### 6. Append-Only Raw Layer with MERGE at Curated

**Choice:** Raw layer is append-only Iceberg; curated layer uses `MERGE INTO` for current state

**Rationale:** Preserves the full CDC event history in the raw layer. Every create, update, and delete operation from Debezium is stored as an immutable append. This provides:

- **Complete audit trail**: Every change to source data is preserved
- **Reproducibility**: Any curated-layer table can be rebuilt from raw events
- **Time-travel**: Iceberg snapshots enable querying the raw layer as of any point in time
- **Compliance**: SEC regulations require demonstrating what data existed at specific times

The curated layer then produces clean, current-state tables via `MERGE INTO` queries (see [`scripts/01_curated/`](../scripts/01_curated/)) that deduplicate the raw event stream by taking the latest event per primary key.

**Implementation detail:** Raw Iceberg tables use `iceberg.tables.upsert-mode-enabled=false` to enforce append-only behavior at the connector level.

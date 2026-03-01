# AWS Data Lake Platform - Architecture Design

## Overview

A secure, auditable, and scalable AWS-based Data Lake/Warehouse platform for an asset management firm. The platform ingests data from RDBMS (via CDC) and Kafka streaming sources, stores it in a medallion architecture (raw/curated/analytics) with MNPI and non-MNPI isolation, and provides role-based query access through Athena with Lake Formation enforcement.

## Decision Log

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | IaC tooling | Terraform + Helm | Industry standard, satisfies deliverable requirements |
| 2 | S3 bucket strategy | Separate buckets per MNPI zone | Physical isolation for regulated data, separate KMS keys and bucket policies |
| 3 | Architecture pattern | Kafka-centric (unified event backbone) | CDC and streaming both flow through MSK; different source patterns, same sink pattern |
| 4 | MSK type | MSK Provisioned (kafka.t3.small x1) | Full topic configuration control needed for Debezium schema history topic |
| 5 | CDC connector | Debezium via Strimzi on EKS | Richer CDC semantics than DMS, Helm chart deliverable via KafkaConnect/KafkaConnector CRDs |
| 6 | Kafka Connect management | Strimzi Operator | Kubernetes-native, declarative connector management, proven GitOps pattern |
| 7 | Schema registry | AWS Glue Schema Registry (Avro) | AWS-native, integrates with MSK and Glue Catalog |
| 8 | Table format | Apache Iceberg | ACID transactions, time-travel for audit, schema evolution for CDC |
| 9 | Query engine | Athena + Lake Formation LF-Tags | Serverless, pay-per-query, LF-Tags for attribute-based MNPI access control |
| 10 | BI layer | QuickSight (feature-flagged) | Full user journey for non-technical personas, optional provisioning |
| 11 | Local dev | Tilt + Kind + ArgoCD | Replicating existing iac-local GitOps bridge pattern |
| 12 | Auditing | CloudTrail S3 data events + LF audit logs + Athena workgroup metrics | Three-tier audit coverage |
| 13 | Metadata tracking | Iceberg snapshots + pipeline_metadata table | Following Roadie datalake metadata.json pattern |
| 14 | MNPI routing | Topic-per-table (structural, not per-row) | Auditable, no runtime classification logic, simpler connector config |
| 15 | Terraform structure | Modules with environment-specific instantiation | Independent state per env, module interfaces enforce documentation |
| 16 | Exactly-once semantics | Transactional producer + read_committed isolation | Required for financial CDC (orders, trades, positions) |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Data Sources                                     │
│                                                                         │
│  ┌──────────────┐         ┌──────────────────────────┐                 │
│  │  PostgreSQL   │         │  External Kafka Producers │                │
│  │  (Sample DB)  │         │  (order-events,           │                │
│  │  EKS Pod      │         │   market-data)            │                │
│  └──────┬───────┘         └────────────┬─────────────┘                 │
│         │ SSL                          │                                │
│         ▼                              │                                │
│  ┌──────────────┐                      │                                │
│  │   Debezium    │                      │                                │
│  │  (Strimzi on  │                      │                                │
│  │   EKS)        │                      │                                │
│  └──────┬───────┘                      │                                │
│         │ IAM Auth + TLS               │                                │
│         ▼                              ▼                                │
│  ┌──────────────────────────────────────────────┐                      │
│  │         MSK Provisioned (kafka.t3.small)      │                      │
│  │                                                │                      │
│  │  CDC Topics:              Streaming Topics:    │                      │
│  │  cdc.trading.orders       stream.order-events  │                      │
│  │  cdc.trading.trades       stream.market-data   │                      │
│  │  cdc.trading.positions    stream.order-events   │                      │
│  │  cdc.trading.accounts       .dlq               │                      │
│  │  cdc.trading.instruments  stream.market-data    │                      │
│  │                             .dlq               │                      │
│  │  Glue Schema Registry (Avro)                   │                      │
│  └───────┬──────────────────────┬────────────────┘                      │
│          │                      │                                        │
│     MNPI Topics            Non-MNPI Topics                              │
│          │                      │                                        │
│          ▼                      ▼                                        │
│  ┌──────────────┐      ┌──────────────┐                                │
│  │ Iceberg Sink  │      │ Iceberg Sink  │                               │
│  │ (MNPI)        │      │ (Non-MNPI)    │                               │
│  │ Strimzi CRD   │      │ Strimzi CRD   │                               │
│  └──────┬───────┘      └──────┬───────┘                                │
│         │ IRSA                 │ IRSA                                    │
│         ▼                      ▼                                        │
│  ┌──────────────┐      ┌──────────────┐                                │
│  │ S3: datalake- │      │ S3: datalake- │                               │
│  │ mnpi-{env}    │      │ nonmnpi-{env} │                               │
│  │               │      │               │                               │
│  │ /raw/         │      │ /raw/         │                               │
│  │ /curated/     │      │ /curated/     │                               │
│  │ /analytics/   │      │ /analytics/   │                               │
│  │               │      │               │                               │
│  │ KMS: mnpi-key │      │ KMS: nonmnpi  │                               │
│  │               │      │     -key      │                               │
│  │ Bucket Policy:│      │ Bucket Policy:│                               │
│  │ Deny direct   │      │ Deny direct   │                               │
│  │ except LF +   │      │ except LF +   │                               │
│  │ DE role       │      │ DE role       │                               │
│  └──────┬───────┘      └──────┬───────┘                                │
│         │                      │                                        │
│         ▼                      ▼                                        │
│  ┌──────────────────────────────────────────────┐                      │
│  │              AWS Glue Catalog                  │                      │
│  │                                                │                      │
│  │  raw_mnpi        raw_nonmnpi                   │                      │
│  │  curated_mnpi    curated_nonmnpi               │                      │
│  │  analytics_mnpi  analytics_nonmnpi             │                      │
│  │                                                │                      │
│  │  LF-Tags: sensitivity=[mnpi|non-mnpi]          │                      │
│  │           layer=[raw|curated|analytics]         │                      │
│  └──────────────────┬───────────────────────────┘                      │
│                      │                                                  │
│                      ▼                                                  │
│  ┌──────────────────────────────────────────────┐                      │
│  │        Lake Formation + Athena                 │                      │
│  │                                                │                      │
│  │  Workgroups:                                   │                      │
│  │  ├─ finance-analysts (MNPI + non-MNPI curated/ │                      │
│  │  │                    analytics)                │                      │
│  │  ├─ data-analysts    (non-MNPI curated/        │                      │
│  │  │                    analytics only)           │                      │
│  │  └─ data-engineers   (all layers, all zones,   │                      │
│  │                       direct S3)                │                      │
│  └──────────────────┬───────────────────────────┘                      │
│                      │                                                  │
│                      ▼                                                  │
│  ┌──────────────────────────────────────────────┐                      │
│  │     QuickSight (feature-flagged)               │                      │
│  │     Trusted Identity Propagation → Athena → LF │                      │
│  └──────────────────────────────────────────────┘                      │
│                                                                         │
│  ┌──────────────────────────────────────────────┐                      │
│  │              Auditing                          │                      │
│  │  CloudTrail: S3 data events on both buckets    │                      │
│  │  Lake Formation: audit logs                    │                      │
│  │  Athena: workgroup query metrics               │                      │
│  │  Destination: s3://datalake-audit-{env}        │                      │
│  │  Retention: 5 years (SEC Rule 204-2)           │                      │
│  └──────────────────────────────────────────────┘                      │
└─────────────────────────────────────────────────────────────────────────┘
```

## Data Model

### Source Tables (PostgreSQL CDC)

**MNPI Zone:**

| Table | Key Fields | MNPI Rationale |
|-------|-----------|----------------|
| orders | order_id, account_id, instrument_id, side, quantity, order_type, status, disclosure_status, created_at, updated_at | Pre-execution trading intent |
| trades | trade_id, order_id, instrument_id, quantity, price, execution_venue, settlement_date, disclosure_status, executed_at | Non-public execution data |
| positions | position_id, account_id, instrument_id, quantity, market_value, position_date, updated_at | Non-public holdings |

**Non-MNPI Zone:**

| Table | Key Fields | Non-MNPI Rationale |
|-------|-----------|-------------------|
| accounts | account_id, account_name, account_type, status, created_at | Reference/metadata |
| instruments | instrument_id, ticker, cusip, isin, name, instrument_type, exchange | Publicly available reference data |

### Streaming Topics

| Topic | Zone | Source | Schema |
|-------|------|--------|--------|
| stream.order-events | MNPI | Trading platform producers | Avro (Glue Schema Registry) |
| stream.market-data | Non-MNPI | Market data feed producers | Avro (Glue Schema Registry) |
| stream.order-events.dlq | MNPI | Failed order events | Same schema |
| stream.market-data.dlq | Non-MNPI | Failed market data events | Same schema |

### CDC Topics (auto-created by Debezium)

| Topic | Zone | Source Table |
|-------|------|-------------|
| cdc.trading.orders | MNPI | orders |
| cdc.trading.trades | MNPI | trades |
| cdc.trading.positions | MNPI | positions |
| cdc.trading.accounts | Non-MNPI | accounts |
| cdc.trading.instruments | Non-MNPI | instruments |

### Iceberg Partition Specs

| Layer | Partition By | Source |
|-------|-------------|--------|
| Raw | `days(source_timestamp)` | Debezium `source.ts_ms` (DB transaction time) |
| Curated | `days(updated_at)` | Most recent `source.ts_ms` after MERGE |
| Analytics | `months(report_date)` | Aggregation period |

### Raw Layer Design

- **Mode**: Append-only (`iceberg.tables.upsert-mode-enabled=false`)
- **Justification**: Preserves full CDC event history (create/update/delete ops). Iceberg provides audit trail via snapshots, schema evolution for source DDL changes. Immutability maintained by append-only config.
- **Curated layer**: `MERGE INTO` (Athena) produces current-state tables from raw CDC event log

### MNPI Routing

- **Mechanism**: Topic-per-table (structural routing)
- **MNPI sink subscribes to**: `cdc.trading.orders`, `cdc.trading.trades`, `cdc.trading.positions`, `stream.order-events`
- **Non-MNPI sink subscribes to**: `cdc.trading.accounts`, `cdc.trading.instruments`, `stream.market-data`
- **Known limitation**: All trades remain in MNPI zone permanently, even after public disclosure. `disclosure_status` provides temporal metadata for analytics within the MNPI zone. Production enhancement: scheduled job to copy disclosed records to non-MNPI curated layer.

## Security Architecture

### S3 Bucket Policy (Lake Formation Bypass Prevention)

Both data lake buckets deny `s3:GetObject` and `s3:PutObject` for all principals except:
- Lake Formation service-linked role
- Kafka Connect IRSA role (direct S3 write for Iceberg sink)
- Data Engineer role (exercise requires direct S3 access)
- Break-glass admin role

### Endpoint Security

| Connection | Security |
|---|---|
| Debezium → PostgreSQL | SSL mode `require` in JDBC URL |
| Debezium → MSK | IAM authentication + TLS in-transit |
| Iceberg Sink → MSK | IAM authentication + TLS in-transit |
| Iceberg Sink → S3 | IRSA scoped to target bucket ARN |
| Athena → S3 | Lake Formation temporary scoped credentials |
| S3 data at rest | KMS encryption, separate CMK per MNPI zone |
| EKS → MSK networking | MSK in private subnets, SG allows port 9098 from EKS node SG |

### IAM Personas

**1. `finance-analyst-role`**
- LF-Tag grant: `SELECT` where `sensitivity IN (mnpi, non-mnpi)` AND `layer IN (curated, analytics)`
- Athena workgroup: `finance-analysts`
- S3: No direct access

**2. `data-analyst-role`**
- LF-Tag grant: `SELECT` where `sensitivity=non-mnpi` AND `layer IN (curated, analytics)`
- Athena workgroup: `data-analysts`
- S3: No direct access

**3. `data-engineer-role`**
- LF-Tag grant: `ALL` where `sensitivity IN (mnpi, non-mnpi)` AND `layer IN (raw, curated, analytics)`
- Additionally: `DATA_LOCATION_ACCESS` on all registered S3 paths
- Athena workgroup: `data-engineers`
- S3: Direct access (exempted from deny policy)

### Exactly-Once Semantics

- Iceberg Kafka Connect Sink configured with transactional producer
- Consumer `isolation.level=read_committed`
- Required for financial CDC (orders, trades, positions) where duplicates are unacceptable

### CloudTrail Scope

- S3 data events enabled on both MNPI and non-MNPI data lake buckets (object-level read/write)
- Management events enabled (Glue, Lake Formation, Athena API calls)
- Log destination: `s3://datalake-audit-{env}` (separate audit bucket)
- Log file validation: Enabled (tamper detection)
- Retention: 5 years per SEC Rule 204-2
- Athena: Glue table registered over audit bucket for querying

## Project Structure

```
data-lake-platform/
├── README.md                           # Quick-start, prerequisites, architecture link
├── Tiltfile                            # Local dev loop (manual trigger mode)
├── Taskfile.yml                        # Lifecycle tasks (up, down, infra, tilt, status)
├── kind-config.yaml                    # 1 CP + 1 worker, port mappings
├── appset-management.yaml              # ArgoCD root Application (*/applicationset.yaml)
├── .sops.yaml                          # Age encryption config
│
├── terraform/
│   ├── local/                          # Kind + ArgoCD bootstrap
│   │   └── main.tf
│   └── aws/
│       ├── modules/
│       │   ├── data-lake-storage/      # S3 buckets, lifecycle, KMS keys, bucket policies
│       │   ├── streaming/              # MSK Provisioned cluster, topic pre-creation
│       │   ├── glue-catalog/           # 6 Glue databases, schema registry
│       │   ├── lake-formation/         # LF-Tags, grants, S3 registrations
│       │   ├── analytics/              # Athena workgroups, named queries, result buckets
│       │   ├── iam-personas/           # 3 persona roles + service roles (IRSA)
│       │   ├── observability/          # CloudTrail, audit bucket, optional QuickSight
│       │   └── networking/             # VPC endpoints, security groups
│       └── environments/
│           ├── dev/                    # Dev: t3.small MSK, no QuickSight, 90-day retention
│           │   ├── main.tf
│           │   ├── terraform.tfvars
│           │   ├── backend.tf
│           │   └── outputs.tf
│           └── prod/                   # Prod: m5.large MSK x3, QuickSight, 5yr retention
│               ├── main.tf
│               ├── terraform.tfvars
│               ├── backend.tf
│               └── outputs.tf
│
├── strimzi/                            # Kafka Connect (Debezium + Iceberg sinks)
│   ├── applicationset.yaml
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── kafka-connect.yaml          # KafkaConnect CRD (image, plugins)
│   │   ├── debezium-source.yaml        # Connector class, transforms, schema registry
│   │   ├── iceberg-sink-mnpi.yaml      # MNPI topic list, Iceberg config, append mode
│   │   └── iceberg-sink-nonmnpi.yaml   # Non-MNPI topic list, Iceberg config, append mode
│   └── overlays/
│       └── localdev/
│           ├── kustomization.yaml
│           ├── debezium-source-patch.yaml     # JDBC URL, server name, table list
│           ├── iceberg-sink-mnpi-patch.yaml   # S3 path, Glue catalog endpoint
│           └── iceberg-sink-nonmnpi-patch.yaml
│
├── sample-postgres/                    # Source RDBMS for CDC demo
│   ├── applicationset.yaml
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── statefulset.yaml
│   │   └── init-schema.sql             # CREATE TABLEs for 5 source tables
│   └── overlays/
│       └── localdev/
│           └── kustomization.yaml
│
├── scripts/
│   ├── 00_seed/
│   │   └── seed-data.sql               # Sample financial data for demo
│   ├── 01_curated/
│   │   ├── curated_orders.sql          # MERGE INTO from raw CDC events
│   │   ├── curated_trades.sql
│   │   ├── curated_positions.sql
│   │   ├── curated_accounts.sql
│   │   └── curated_instruments.sql
│   ├── 02_analytics/
│   │   ├── analytics_trade_summary.sql
│   │   └── analytics_position_report.sql
│   └── validation/
│       ├── access_validation.sql       # MNPI vs non-MNPI access demo per persona
│       └── iceberg_time_travel.sql     # Demonstrate Iceberg snapshot queries
│
└── docs/
    ├── plans/
    │   └── 2026-02-28-data-lake-platform-design.md  # This document
    ├── architecture-diagram.png        # Visual diagram (generated from ASCII above)
    └── documentation.md                # Full documentation deliverable
```

## Implementation vs Documentation Scope

| Component | Implement | Document Only |
|---|---|---|
| Terraform modules (dev env) | Yes | |
| Terraform prod env | | Yes (tfvars placeholder) |
| S3 buckets + KMS + bucket policies | Yes | |
| MSK Provisioned (single broker) | Yes | |
| Glue databases + schema registry | Yes | |
| Lake Formation LF-Tags + grants | Yes | |
| Athena workgroups + named queries | Yes | |
| IAM persona roles | Yes | |
| CloudTrail + audit bucket | Yes | |
| QuickSight | | Yes (feature-flagged) |
| VPC endpoints + SGs | Yes (minimal) | Yes (production sizing) |
| Strimzi + Debezium + Iceberg sinks | Yes | |
| Sample PostgreSQL + seed data | Yes | |
| Curated MERGE transforms (Athena) | Yes | |
| Analytics aggregation queries | Yes | |
| Access validation queries | Yes | |
| Iceberg time-travel demo | Yes | |
| Kind + Tilt + ArgoCD local dev | Yes | |
| dbt for transforms | | Yes (production path) |
| Multi-AZ MSK | | Yes (production path) |

# Reviewer Guide

Self-service guide for evaluating the Data Lake Platform. Everything here runs without the candidate's intervention.

**Time estimate:** 30-45 minutes for full review, 15 minutes for quick verification.

**Prerequisites:** [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), [Terraform >= 1.7](https://developer.hashicorp.com/terraform/install), [Task](https://taskfile.dev/installation)

---

## Credentials

| Field | Value |
|-------|-------|
| **SSO Portal** | https://mayadangelou.awsapps.com/start |
| **Username** | `krakenreviewer` |
| **Password** | ``2y"tm8=e`Hh9`` |

## Getting Started (3 commands)

```bash
# 1. Check tools are installed
task reviewer:check

# 2. Configure AWS SSO (writes a 'data-lake' profile to ~/.aws/config)
task reviewer:sso

# 3. Log in (opens browser — sign in with the credentials above)
task reviewer:login

# 4. Verify everything works
task reviewer:verify

# 5. Run end-to-end pipeline test (~3 min)
#    Invokes Lambda → verifies data flows through Aurora → Debezium → MSK → Iceberg → S3
task reviewer:e2e

# 6. Query data across all layers
task reviewer:sample-queries
```

---

## AWS Console Access (SSO)

A reviewer account has been pre-created in IAM Identity Center. Log in at **https://mayadangelou.awsapps.com/start** with the credentials above.

You'll see **4 roles** in the SSO portal:

| Role | Purpose | What You Can Do |
|------|---------|----------------|
| **Reviewer** | Infrastructure review | Full AWS access (AdministratorAccess + permission boundary). Use this for `terraform plan/apply`, Glue console, CloudWatch, S3, etc. |
| **FinanceAnalyst** | ABAC testing | MNPI + non-MNPI data, curated + analytics layers only |
| **DataAnalyst** | ABAC testing | Non-MNPI data only, curated + analytics layers only |
| **DataEngineer** | ABAC testing | All zones, all layers, plus direct S3 access |

**Use the Reviewer role** for exploring infrastructure (Glue jobs, MSK connectors, Aurora, Lambda, etc.). Use the persona roles to test Lake Formation access control in Athena.

### Athena Workgroups

When testing ABAC with persona roles, select the matching workgroup in Athena:
- `finance-analysts-prod` (for FinanceAnalyst role)
- `data-analysts-prod` (for DataAnalyst role)
- `data-engineers-prod` (for DataEngineer role)

### Verify Access Control Works

Try these queries to see Lake Formation ABAC in action:

**As FinanceAnalyst** (MNPI access, curated/analytics only):
```sql
-- SUCCEEDS: Finance analysts can see MNPI curated data
SELECT count(*) AS total_orders FROM curated_mnpi_prod.order_events;

-- SUCCEEDS: Finance analysts can see non-MNPI analytics
SELECT * FROM analytics_nonmnpi_prod.market_summary LIMIT 5;

-- FAILS (AccessDeniedException): Finance analysts cannot access raw layer
SELECT count(*) FROM raw_mnpi_prod.orders;
```

**As DataAnalyst** (non-MNPI only):
```sql
-- SUCCEEDS: Non-MNPI curated data
SELECT count(*) FROM curated_nonmnpi_prod.market_ticks;

-- FAILS (AccessDeniedException): Data analysts cannot see MNPI data
SELECT count(*) FROM curated_mnpi_prod.order_events;
```

**As DataEngineer** (full access):
```sql
-- SUCCEEDS: Raw layer access
SELECT count(*) FROM raw_mnpi_prod.orders;

-- Iceberg time-travel: list snapshots
SELECT snapshot_id, committed_at, operation,
       summary['added-records'] AS added,
       summary['total-records'] AS total
FROM raw_mnpi_prod."orders$snapshots"
ORDER BY committed_at DESC LIMIT 10;
```

### CLI Access

The `task reviewer:sso` command configures a `data-lake` profile using the Reviewer role. If you prefer manual setup:

```bash
# Already done by 'task reviewer:sso', but for reference:
aws configure sso
# SSO start URL: https://mayadangelou.awsapps.com/start
# SSO Region: us-east-1
# Select the Reviewer role for full access

# Login
aws sso login --profile data-lake

# Test
aws sts get-caller-identity --profile data-lake
```

---

## Quick Start — Code Review (5 minutes)

```bash
# 1. Extract the submission
unzip data-lake-platform.zip && cd data-lake-platform

# 2. Review architecture
open generated-diagrams/data-lake-platform-full-architecture.png

# 3. Count Terraform resources (~200 in prod)
cd terraform/aws
grep -r "^resource " modules/ | wc -l

# 4. Review module structure
ls modules/
```

The platform is fully deployed in AWS account `445985103066` (us-east-1). All infrastructure is live and producing data.

---

## 1. Architecture at a Glance

### What This Platform Does

A secure, auditable data lake for an asset management firm that:

1. **Ingests** trading data via CDC (Aurora PostgreSQL -> Debezium -> MSK -> Iceberg) and streaming (Lambda -> MSK -> Iceberg)
2. **Isolates** MNPI (Material Non-Public Information) from non-MNPI data at every layer — separate S3 buckets, KMS keys, Kafka topics, and Glue databases
3. **Transforms** raw events through a medallion architecture (raw -> curated -> analytics) using Glue ETL PySpark jobs
4. **Controls access** via Lake Formation LF-Tags (attribute-based) with three IAM Identity Center personas
5. **Audits** all data access via CloudTrail S3 data events with 5-year retention

### Key Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Compute | Fully serverless (Lambda + MSK Connect + Glue) | No EKS — eliminates node management for event-driven workloads |
| CDC | Debezium via MSK Connect | Managed Kafka Connect — auto-recovery, no pods |
| Table Format | Apache Iceberg | Native Athena support, ACID transactions, time-travel for audit |
| Access Control | LF-Tags (ABAC) | 2 tag keys create 6 access combinations; new tables auto-inherit |
| MNPI Routing | Topic-per-sink | Structural isolation — no runtime classification code |

### Data Flow

```
EventBridge (1 min) --> Lambda Trading Simulator
                             |
                             +--> Aurora PostgreSQL (RDS Data API)
                             |       '--> Debezium CDC (WAL) --> MSK
                             |                                    |
                             '--> MSK (direct produce: market data)
                                                              |
                                  MSK Connect Iceberg Sinks <-'
                                       |
                             +---------+----------+
                             v                     v
                           S3 MNPI Bucket     S3 Non-MNPI Bucket
                           (6 Iceberg tables)  (per-topic tables)
                             |                     |
                             '---------+-----------'
                                       v
                              Glue ETL (4 PySpark jobs)
                              raw -> curated -> analytics
                                       |
                                       v
                              Athena (3 workgroups)
                                       |
                                       v
                              QuickSight dashboards
```

---

## 2. What to Review (by area)

### Infrastructure as Code

| Area | Key Files | What to Look For |
|------|-----------|-----------------|
| Root module | `terraform/aws/main.tf` | Module wiring, feature flags via `count` |
| Environment config | `terraform/aws/locals.tf` | Dev vs prod differences (single source of truth) |
| S3 security | `modules/data-lake-storage/main.tf` | DENY bucket policies (lines ~375-437), KMS CMKs |
| Lake Formation | `modules/lake-formation/main.tf` | LF-Tags, ABAC grants, IC integration |
| IAM roles | `modules/service-roles/main.tf` | Least-privilege policies, `/datalake/` path convention |
| MSK Connect | `modules/msk-connect/main.tf` | Debezium + Iceberg sink connector configs |
| Networking | `modules/networking/main.tf` | VPC, private subnets, NAT, S3/STS endpoints |

### ETL Pipeline

| Area | Key Files | What to Look For |
|------|-----------|-----------------|
| Glue Terraform | `modules/glue-etl/main.tf` | `for_each` pattern, workflow + triggers |
| Curated orders | `scripts/glue/curated_order_events.py` | CDC filter (`_cdc.op != 'd'`), dedup, type casting |
| Curated ticks | `scripts/glue/curated_market_ticks.py` | Dedup by `tick_id`, spread/mid_price derivation |
| Analytics orders | `scripts/glue/analytics_order_summary.py` | Per-instrument aggregation, buy/sell ratio |
| Analytics market | `scripts/glue/analytics_market_summary.py` | Per-ticker aggregation, spread % |

### Security

| Area | Key Files | What to Look For |
|------|-----------|-----------------|
| Bucket policies | `modules/data-lake-storage/main.tf` | S3 DENY — blocks all except allowlisted ARNs |
| KMS isolation | `modules/data-lake-storage/main.tf` | Separate CMK per sensitivity zone |
| Identity Center | `modules/identity-center/` | 3 groups, permission sets, demo users |
| LF grants | `modules/lake-formation/main.tf` | Tag-based grants (sensitivity + layer AND logic) |
| Audit trail | `modules/observability/main.tf` | CloudTrail S3 data events on both data buckets |

### Lambda Trading Simulator

| Area | Key Files | What to Look For |
|------|-----------|-----------------|
| Handler | `scripts/lambda/trading_simulator/main.py` | Powertools Logger + Tracer, warm reuse |
| Simulator | `scripts/lambda/trading_simulator/simulator.py` | 8 instruments, 5 accounts, price jitter |
| DB client | `scripts/lambda/trading_simulator/database.py` | RDS Data API (not direct PG connection) |
| Kafka producer | `scripts/lambda/trading_simulator/producer.py` | IAM auth, reconnect-on-failure |

---

## 3. Verification Commands (Read-Only)

All commands below are **read-only** — they inspect deployed resources without modifying anything. They require the `data-lake` AWS CLI profile.

### Prerequisites

If you haven't already, run the Taskfile onboarding:

```bash
task reviewer:sso    # Configure AWS CLI profile (one-time)
task reviewer:login  # Log in via SSO (opens browser)
task reviewer:verify # Quick status check of all components
```

> **No AWS access?** Skip to [Section 4: Code Review](#4-code-review-no-aws-access-needed) — the code itself tells the full story.

### 3a. Infrastructure Inventory

```bash
# Count deployed resources
terraform -chdir=terraform/aws workspace select prod
terraform -chdir=terraform/aws state list | wc -l
# Expected: ~200 resources

# List all modules
terraform -chdir=terraform/aws state list | grep "^module\." | cut -d. -f1-2 | sort -u

# Check MSK cluster status
aws kafka list-clusters-v2 --query 'ClusterInfoList[].{Name:ClusterName,State:State}' --output table

# Check Aurora cluster status
aws rds describe-db-clusters --db-cluster-identifier datalake-prod \
  --query 'DBClusters[0].{Status:Status,Engine:Engine,EngineVersion:EngineVersion}' --output table
```

### 3b. MSK Connect Connectors (CDC Pipeline)

```bash
# List all connectors — expect 3 RUNNING
aws kafkaconnect list-connectors \
  --query 'connectors[].{Name:connectorName,State:connectorState}' --output table

# Expected output:
# debezium-source-prod     RUNNING
# iceberg-sink-mnpi-prod   RUNNING
# iceberg-sink-nonmnpi-prod RUNNING

# Check Debezium connector config (CDC source)
aws kafkaconnect describe-connector --connector-arn \
  $(aws kafkaconnect list-connectors --query 'connectors[?connectorName==`debezium-source-prod`].connectorArn' --output text) \
  --query 'connectorConfiguration' --output json | python3 -m json.tool | head -30
```

### 3c. Raw Data (Iceberg Tables in S3)

```bash
# List raw MNPI Iceberg tables (orders, trades, positions)
aws s3 ls s3://datalake-mnpi-prod/ --recursive | head -20

# List raw non-MNPI Iceberg tables (market_data, accounts, instruments)
aws s3 ls s3://datalake-nonmnpi-prod/ --recursive | head -20

# Check Glue databases
aws glue get-databases --query 'DatabaseList[].Name' --output table
# Expected: raw_mnpi_prod, raw_nonmnpi_prod, curated_mnpi_prod, curated_nonmnpi_prod, analytics_mnpi_prod, analytics_nonmnpi_prod

# List tables in raw MNPI database
aws glue get-tables --database-name raw_mnpi_prod \
  --query 'TableList[].{Name:Name,Type:Parameters.table_type}' --output table
# Expected: orders, trades, positions (all ICEBERG)
```

### 3d. Glue ETL Pipeline

```bash
# List Glue workflows
aws glue get-workflow --name datalake-medallion-prod \
  --query 'Workflow.{Name:Name,CreatedOn:CreatedOn}' --output table

# List Glue jobs
aws glue get-jobs --query 'Jobs[].{Name:Name,GlueVersion:GlueVersion,Workers:NumberOfWorkers}' --output table

# Check most recent workflow run
aws glue get-workflow-runs --name datalake-medallion-prod --max-results 1 \
  --query 'Runs[0].{Status:Status,StartedOn:StartedOn,CompletedOn:CompletedOn}' --output table

# Verify all 4 jobs succeeded in latest run
aws glue get-workflow-runs --name datalake-medallion-prod --max-results 1 \
  --query 'Runs[0].Graph.Nodes[?Type==`JOB`].{Name:Name,Status:JobDetails.JobRuns[0].JobRunState}' --output table
# Expected: 4 rows, all SUCCEEDED
```

### 3e. Athena Queries (Data Verification)

```bash
# Row counts across all layers
aws athena start-query-execution \
  --query-string "
    SELECT 'raw_mnpi.orders' AS table_name, count(*) AS rows FROM raw_mnpi_prod.orders
    UNION ALL SELECT 'raw_mnpi.trades', count(*) FROM raw_mnpi_prod.trades
    UNION ALL SELECT 'raw_mnpi.positions', count(*) FROM raw_mnpi_prod.positions
    UNION ALL SELECT 'raw_nonmnpi.market_data', count(*) FROM raw_nonmnpi_prod.market_data
    UNION ALL SELECT 'curated_mnpi.order_events', count(*) FROM curated_mnpi_prod.order_events
    UNION ALL SELECT 'curated_nonmnpi.market_ticks', count(*) FROM curated_nonmnpi_prod.market_ticks
    UNION ALL SELECT 'analytics_mnpi.order_summary', count(*) FROM analytics_mnpi_prod.order_summary
    UNION ALL SELECT 'analytics_nonmnpi.market_summary', count(*) FROM analytics_nonmnpi_prod.market_summary
  " \
  --work-group data-engineers-prod \
  --query 'QueryExecutionId' --output text

# Wait ~10 seconds, then fetch results:
# aws athena get-query-results --query-execution-id <QID> --output table

# Sample curated order data
aws athena start-query-execution \
  --query-string "SELECT order_id, instrument_id, side, quantity, status, is_buy, created_at FROM curated_mnpi_prod.order_events LIMIT 10" \
  --work-group data-engineers-prod \
  --query 'QueryExecutionId' --output text

# Analytics summary
aws athena start-query-execution \
  --query-string "SELECT * FROM analytics_mnpi_prod.order_summary ORDER BY total_orders DESC" \
  --work-group data-engineers-prod \
  --query 'QueryExecutionId' --output text

# Iceberg time-travel — list snapshots (audit trail)
aws athena start-query-execution \
  --query-string "SELECT snapshot_id, committed_at, operation, summary['added-records'] AS added, summary['total-records'] AS total FROM raw_mnpi_prod.\"orders\$snapshots\" ORDER BY committed_at DESC LIMIT 10" \
  --work-group data-engineers-prod \
  --query 'QueryExecutionId' --output text
```

### 3f. Lake Formation Access Control

```bash
# List LF-Tags
aws lakeformation list-lf-tags --query 'LFTags[].{Key:TagKey,Values:TagValues}' --output table
# Expected: sensitivity (mnpi, non-mnpi), layer (raw, curated, analytics)

# Check LF data lake settings (IAMAllowedPrincipals removed)
aws lakeformation get-data-lake-settings --query 'DataLakeSettings.DataLakeAdmins' --output table

# List S3 registrations with Lake Formation
aws lakeformation list-resources --query 'ResourceInfoList[].ResourceArn' --output table
```

### 3g. Audit & Observability

```bash
# CloudTrail status
aws cloudtrail describe-trails --query 'trailList[].{Name:Name,S3BucketName:S3BucketName,IsLogging:HasInsightSelectors}' --output table

# S3 data events being captured
aws cloudtrail get-event-selectors --trail-name datalake-s3-audit-prod \
  --query 'AdvancedEventSelectors' --output json | python3 -m json.tool | head -30

# QuickSight data source
aws quicksight list-data-sources --aws-account-id 445985103066 \
  --query 'DataSources[].{Name:Name,Type:Type,Status:Status}' --output table

# Lambda invocations (trading simulator)
aws lambda get-function --function-name datalake-trading-simulator-prod \
  --query 'Configuration.{Name:FunctionName,Runtime:Runtime,MemorySize:MemorySize,Timeout:Timeout}' --output table
```

---

## 4. Code Review (No AWS Access Needed)

Even without AWS credentials, the full architecture is reviewable from the codebase alone.

### Architecture Validation Checklist

- [ ] **MNPI isolation**: Separate S3 buckets (`data-lake-storage`), separate KMS CMKs, separate Glue databases (`glue-catalog`), topic-per-sink routing (`msk-connect`)
- [ ] **S3 DENY policies**: `data-lake-storage/main.tf` — bucket policies block all access except Lake Formation SLR and allowlisted IAM roles
- [ ] **Lake Formation ABAC**: `lake-formation/main.tf` — LF-Tags (`sensitivity`, `layer`) with AND-logic grants per IC group
- [ ] **Least-privilege IAM**: `service-roles/main.tf` — each role scoped to its specific resources (no `*` on data actions)
- [ ] **CDC pipeline**: Aurora -> Debezium -> MSK -> Iceberg Sink -> S3 (review `msk-connect/main.tf` connector configs)
- [ ] **Medallion transforms**: 4 PySpark scripts in `scripts/glue/` — filter, dedup, cast, derive, DQ check, write
- [ ] **Audit trail**: CloudTrail S3 data events on both data buckets (`observability/main.tf`), 5-year retention
- [ ] **Environment isolation**: `locals.tf` config map drives dev/prod differences; feature flags gate prod-only modules

### Terraform Module Quality

```bash
# Validate all Terraform
cd terraform/aws
terraform init -backend=false > /dev/null 2>&1
terraform validate
# Expected: Success! The configuration is valid.

# Count resources per module
for mod in modules/*/; do
  count=$(grep -c "^resource " "$mod"*.tf 2>/dev/null || echo 0)
  echo "$mod: $count resources"
done
```

### PySpark Script Review Points

1. **Iceberg catalog registration** — All 4 scripts manually register `glue_catalog` via `SparkSession.builder.config()` (required — `--datalake-formats=iceberg` only adds JARs)
2. **CDC handling** — `curated_order_events.py` filters `_cdc.op != 'd'` to exclude deletes
3. **Deduplication** — Both curated jobs use `ROW_NUMBER` window functions for idempotent dedup
4. **Data quality gates** — `assert_quality()` fails the job on DQ violations (no corrupt data reaches downstream)
5. **Iceberg write pattern** — `df.writeTo(...).using("iceberg").createOrReplace()` (full refresh, idempotent)

---

## 5. Deployed Resource Summary

| Component | Count | Status |
|-----------|-------|--------|
| Terraform modules | 14 | All deployed |
| S3 buckets | 4 (MNPI + non-MNPI + audit + query-results) | Active |
| KMS CMKs | 2 (one per sensitivity zone) | Key rotation enabled |
| Glue databases | 6 (3 layers x 2 zones) | Active |
| Iceberg tables | ~8 raw + 2 curated + 2 analytics | Active |
| MSK brokers | 2 (m5.large, one per AZ) | ACTIVE |
| MSK Connect connectors | 3 (Debezium + 2 Iceberg sinks) | RUNNING |
| Aurora instances | 2 (r6g.large, writer + reader) | Available |
| Glue ETL jobs | 4 (2 curated + 2 analytics) | Last run: SUCCEEDED |
| Glue workflow | 1 (medallion pipeline) | Scheduled every 6h |
| Lambda functions | 1 (trading simulator) | EventBridge every 1 min |
| Athena workgroups | 3 (per persona) | Active |
| IC groups | 3 (FinanceAnalysts, DataAnalysts, DataEngineers) | Active |
| LF-Tag keys | 2 (sensitivity, layer) | Active |
| CloudTrail | 1 (S3 data events) | Logging |
| QuickSight | 1 data source (Athena connector) | CREATION_SUCCESSFUL |

---

## 6. Key Documents

| Document | Purpose |
|----------|---------|
| [`README.md`](../README.md) | Project overview, deployment, module index |
| [`docs/documentation.md`](documentation.md) | Full technical documentation (data model, security, ETL lineage) |
| [`docs/plans/`](plans/) | Design and implementation plans |
| [`terraform/aws/locals.tf`](../terraform/aws/locals.tf) | Environment config (dev vs prod) |
| [`scripts/init-aurora-cdc.sh`](../scripts/init-aurora-cdc.sh) | Aurora CDC setup (table schemas, Debezium publication) |
| [`scripts/upload-connector-plugins.sh`](../scripts/upload-connector-plugins.sh) | MSK Connect plugin packaging |
| [`scripts/build_lambda.sh`](../scripts/build_lambda.sh) | Lambda deployment artifact build |

---

## 7. Available Taskfile Commands

```bash
# Reviewer onboarding
task reviewer:check              # Verify tools installed (aws, terraform, task)
task reviewer:sso                # Configure AWS SSO profile (one-time)
task reviewer:login              # Log in via SSO (opens browser)
task reviewer:verify             # Status check: databases, connectors, jobs, Lambda
task reviewer:e2e                # End-to-end pipeline test: Lambda → Aurora → CDC → S3 (~3 min)
task reviewer:sample-queries     # Row counts across all 8 tables
task reviewer:access-control-demo # Instructions for testing ABAC with different roles

# Data queries
task athena:query QUERY="SELECT count(*) FROM raw_mnpi_prod.orders" WORKGROUP=data-engineers-prod
task athena:demo                 # Demo queries across all medallion layers

# Infrastructure (read-only inspection)
task validate:tf                 # Validate Terraform configuration
```

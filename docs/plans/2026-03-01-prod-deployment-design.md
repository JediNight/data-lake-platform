# Production Deployment Design

**Date**: 2026-03-01
**Status**: Approved
**Author**: Senior Data Engineer (AI-assisted)

## Context

Phase 2 (Glue ETL medallion pipeline) is complete and validated in dev. All 4 jobs
succeed end-to-end. This design covers deploying the full production stack.

### Key Decision: No EKS

MSK Connect runs Debezium and Iceberg sink connectors as a fully managed service —
no Kubernetes required for the streaming pipeline. The producer-api (trading
simulator) is a bursty, low-frequency workload better suited to Lambda + API Gateway
than a persistent EKS deployment.

This eliminates: EKS cluster, ArgoCD, GitOps repo, ECR, Strimzi operator.
Result: 100% serverless/managed architecture. Everything is Terraform.

## Architecture

```
Lambda (Producer API)
    │                               │
    │ Orders (INSERT)               │ Market data (direct)
    ▼                               ▼
Aurora PostgreSQL             MSK Provisioned (3 brokers, IAM auth, TLS)
    │                               ▲              │
    │ WAL (pgoutput)                │              │
    ▼                               │              ▼
Debezium Source (MSK Connect) ──────┘     Iceberg Sink NonMNPI
    │                                        │
    ▼                                        ▼
cdc.trading.* topics                S3 (datalake-nonmnpi-prod/raw/)
    │
    ▼
Iceberg Sink MNPI ──────────▶ S3 (datalake-mnpi-prod/raw/)
    │
    ▼
Glue ETL Medallion Pipeline (SCHEDULED every 6 hours)
  • curated_order_events    (raw → curated, dedup)
  • curated_market_ticks    (raw → curated, dedup)
  • analytics_order_summary (curated → analytics, aggregate)
  • analytics_market_summary(curated → analytics, aggregate)
    │
    ▼
Athena (3 workgroups: finance-analysts, data-analysts, data-engineers)
    │
    ▼
Lake Formation (LF-Tag ABAC: sensitivity × layer, 3 personas)
    │
    ▼
Identity Center (trusted identity propagation)

Audit: CloudTrail S3 data events → 5-year retention (SEC Rule 204-2)
```

## Terraform Modules

### Kept (no changes)
- `networking` — VPC, 2 private subnets, S3 gateway endpoint, security groups
- `streaming` — MSK Provisioned cluster
- `data-lake-storage` — 4 S3 buckets, 2 KMS CMKs, DENY policies
- `glue-catalog` — 6 databases, schema registry
- `lake-formation` — LF-Tags, ABAC grants, IC integration
- `analytics` — 3 Athena workgroups
- `observability` — CloudTrail, audit table
- `identity-center` — 3 personas, permission sets

### Modified
- `service-roles` — Already updated (extra S3 read, CloudWatch metrics)
- `glue-etl` — Add SCHEDULED trigger (every 6 hours)
- `aurora-postgres` — Fix secrets recovery window (0 → 7 days)
- `msk-connect` — Wire real Aurora endpoint + MSK bootstrap brokers

### New
- `lambda-producer` — Lambda function + API Gateway for producer-api

### Removed
- `eks` — Replaced by Lambda + MSK Connect (fully managed)

## New Module: lambda-producer

FastAPI wrapped with Mangum for Lambda compatibility.

### Resources
- `aws_lambda_function` — Python 3.11 runtime, VPC-attached
- `aws_api_gateway_rest_api` + integration — HTTP proxy to Lambda
- `aws_iam_role` — Lambda execution role (MSK write via IAM, Aurora read/write)
- `aws_security_group` — Lambda SG (egress to MSK + Aurora)

### Lambda VPC Placement
Lambda must be in the VPC to reach:
- MSK brokers (port 9098, IAM auth) — private subnets only
- Aurora PostgreSQL (port 5432) — private subnets only

This requires a NAT Gateway for Lambda to reach AWS service endpoints
(CloudWatch Logs, Secrets Manager). Added to networking module.

## Security Fixes (3 items)

1. **Aurora secrets recovery window**: Change `recovery_window_in_days` from 0 to 7
   in `modules/aurora-postgres/main.tf:61`

2. **EKS removal**: Eliminates the EKS node SG and API CIDR issues entirely
   (no longer applicable)

3. **MSK IAM authentication**: Already configured in `msk-connect` module
   (`authentication_type = "IAM"`, `encryption_type = "TLS"`)

## Glue ETL Changes

### Scheduled Trigger
Replace ON_DEMAND start trigger with SCHEDULED (every 6 hours):
```hcl
schedule = "cron(0 */6 * * ? *)"  # Every 6 hours
```

### Data Quality Checks (Lightweight)
Add to each PySpark script after transforms, before writes:
- Row count > 0 assertion
- No null primary keys
- Log metrics to CloudWatch
- Fail the job if assertions fail (prevents bad data propagation)

## Networking Changes

### NAT Gateway (new)
Required for VPC-attached Lambda to reach AWS endpoints:
- Add public subnet (for NAT Gateway placement)
- Add Internet Gateway
- Add NAT Gateway
- Update private route table with 0.0.0.0/0 → NAT Gateway

### Security Group Updates
- Add Lambda SG (egress to MSK 9098 + Aurora 5432)
- Add MSK SG ingress from Lambda SG
- Add Aurora SG ingress from Lambda SG (in addition to existing MSK Connect)

## Prod Configuration (locals.tf)

```
MSK:        kafka.m5.large × 3, replication factor 3
Aurora:     db.r6g.large × 2
Glue:       G.1X × 5 workers per job
Athena:     1 TB scan limit, result reuse enabled
CloudTrail: 1825-day retention (5 years)
S3:         90-day IA transition on raw layer
```

## Deployment Order

1. Push to GitHub (jediNight/data-lake-platform)
2. `terraform workspace select prod`
3. `terraform apply -var-file=prod.tfvars` — creates all resources
4. Upload Debezium + Iceberg connector JARs to S3 plugin bucket
5. Seed Aurora with initial schema + data
6. Verify MSK Connect connectors reach RUNNING state
7. Trigger producer Lambda to generate events
8. Run Glue workflow manually (first run), verify scheduled trigger
9. Query analytics tables via Athena
10. Validate Lake Formation access controls (3 personas)

## Cost Estimate (prod)

| Service | Monthly Cost |
|---------|-------------|
| MSK (3 × m5.large) | ~$600 |
| Aurora (2 × r6g.large) | ~$350 |
| MSK Connect (3 connectors × 1 MCU) | ~$240 |
| NAT Gateway | ~$45 |
| Glue ETL (4 jobs × 5 workers × 4 runs/day) | ~$50 |
| Lambda + API Gateway | ~$5 |
| S3 + KMS | ~$20 |
| **Total** | **~$1,310/mo** |

Note: Tear down after submission to stop costs. Dev environment costs ~$5/mo.

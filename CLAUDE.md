# Data Lake Platform

Secure, auditable AWS data lake with MNPI/non-MNPI isolation for an asset management firm. Real-time CDC and streaming ingestion into Apache Iceberg tables on S3, with Lake Formation ABAC and a medallion architecture powered by Glue ETL.

## Quick Reference

```bash
# Tools — install everything at once
mise install                          # Installs terraform, aws-cli, kind, kubectl, etc.

# Reviewer onboarding (one command)
./scripts/reviewer-setup.sh           # Configure SSO + login + verify (all-in-one)
# Or step by step:
task reviewer:check                   # Verify tools installed
task reviewer:sso                     # Configure AWS SSO profile
task reviewer:login                   # Authenticate via SSO (opens browser)
task reviewer:verify                  # Full infrastructure status check

# Data validation
task athena:demo                      # Query all medallion layers
task reviewer:sample-queries          # Row counts across all 8 tables
task reviewer:e2e                     # End-to-end pipeline test (~3 min)

# Kafka/CDC debugging
task reviewer:kafka-status            # MSK cluster + connector health
task reviewer:topics                  # List Kafka topics + partition counts
task reviewer:cdc-status              # Aurora replication slot, publication, row counts
task reviewer:connector-logs          # Tail connector logs (FILTER=ERROR for errors)
task reviewer:s3-freshness            # Latest Iceberg data files per table

# Infrastructure (stacks-based)
task tf:init-all                      # Initialize all 5 Terraform stacks
task tf:plan-all                      # Plan all stacks in dependency order
task deploy:all                       # Deploy all stacks (tiered parallel execution)
task destroy:all                      # Destroy in reverse dependency order

# Single stack operations
task tf:init STACK=foundation         # Init one stack
task tf:plan STACK=compute            # Plan one stack
task deploy:foundation                # Deploy one stack (auto-inits)

# Local dev
task dev:up                           # Kind + ArgoCD + Strimzi + all AWS stacks
task dev:down                         # Tear down everything
task dev:tilt                         # Start Tilt inner dev loop
```

## Architecture

### Data Flow

```
Lambda Trading Simulator (EventBridge 1min)
    |
    +---> Aurora PostgreSQL (INSERT via RDS Data API)
    |         |
    |         +---> Debezium CDC (WAL) ---> MSK topics: cdc.trading.{orders,trades,positions,accounts,instruments}
    |
    +---> MSK topic: stream.market-data (direct produce)
              |
    MSK Connect Iceberg Sinks <----+
         |                    |
    S3 MNPI Bucket       S3 Non-MNPI Bucket
    (orders,trades,      (market_data,accounts,
     positions)           instruments)
         |                    |
    Glue ETL (4 PySpark jobs): raw -> curated -> analytics
         |
    Athena (3 workgroups) -> QuickSight
```

### Terraform Stacks (Dependency Order)

```
Tier 0 (one-time):  account-baseline (Identity Center, LF settings, LF-Tags, QuickSight)
                     — no workspaces, uses default workspace

Tier 1 (parallel):  foundation (VPC, subnets, SGs)
                     data-lake-core (S3, KMS, Glue catalog)

Tier 2 (parallel):  security (Lake Formation grants, ABAC, observability)
                     compute (MSK, Aurora)

Tier 3 (sequential): pipelines (MSK Connect, Lambda, Glue ETL, analytics)
```

Each stack has its own S3 state file at `s3://mayadangelou-datalake-tfstate/{stack}/terraform.tfstate`. The `account-baseline` stack manages account-global singletons that cannot be workspace-isolated (Identity Center groups, LF-Tags, QuickSight subscription). The `security` stack references these via AWS data sources (not terraform_remote_state), keeping stacks decoupled.

## Project Structure

```
terraform/aws/
  stacks/                    6 decomposed stacks (the deployment units)
    account-baseline/        Identity Center, LF settings, LF-Tags, QuickSight (no workspaces)
    foundation/              VPC, subnets, NAT GW, security groups
    data-lake-core/          S3 buckets, KMS CMKs, Glue databases
    security/                Lake Formation grants, ABAC, service roles, bucket policies
    compute/                 MSK cluster, Aurora PostgreSQL
    pipelines/               MSK Connect connectors, Lambda, Glue ETL, Athena
  modules/                   14 shared Terraform modules (used by stacks)
scripts/
  glue/                      4 PySpark ETL scripts (medallion transforms)
  lambda/trading_simulator/  Lambda source code (FastAPI + Mangum)
  verify-e2e-pipeline.sh     End-to-end data flow verification
  init-aurora-cdc.sh         Aurora CDC setup (replication slot + publication)
  upload-connector-plugins.sh  Build MSK Connect plugin ZIPs
dev/                         Local dev environment (Kind, ArgoCD, Strimzi)
Taskfile.yml                 All tasks (reviewer, deploy, destroy, debug)
mise.toml                    Tool version management
```

## Key Conventions

### Terraform

- **Workspace-driven**: `dev` and `prod` workspaces. Stacks use `terraform.workspace` in locals to select environment-specific config (instance sizes, broker counts, feature flags).
- **No root module**: The monolithic `terraform/aws/main.tf` has been removed. All operations use stacks.
- **Modules are shared**: `terraform/aws/modules/` is referenced by multiple stacks via relative paths.
- **State isolation**: Each stack has its own S3 state key. Never mix state across stacks.

### Naming

- AWS resources: `datalake-{component}-{environment}` (e.g., `datalake-msk-prod`)
- S3 buckets: `datalake-{zone}-{environment}` (e.g., `datalake-mnpi-prod`)
- Glue databases: `{layer}_{zone}_{environment}` (e.g., `raw_mnpi_prod`)
- Kafka topics: `cdc.trading.{table}` for CDC, `stream.{source}` for direct produce

### MNPI Isolation

MNPI (Material Non-Public Information) and non-MNPI data are strictly separated:
- Separate S3 buckets with separate KMS CMKs
- Separate Kafka topics and Iceberg sink connectors
- Separate Glue databases per layer per zone
- Lake Formation ABAC tags (`sensitivity=mnpi|nonmnpi`, `layer=raw|curated|analytics`)

### MSK Connect & Debezium

- Plugin format: Must be real ZIP (not tar.gz renamed)
- Aurora PG 15 SSL: `database.sslmode = "require"` mandatory
- Topic naming: `DefaultTopicNamingStrategy` produces `{prefix}.{table}` (not `{prefix}.{schema}.{table}`)
- Converters: JsonConverter with `schemas.enable=false` on both source and sinks
- Iceberg sink commits every 120 seconds — data freshness has ~2 min lag
- Control topics (`control-iceberg-mnpi`, `control-iceberg-nonmnpi`) coordinate exactly-once commits

### Glue ETL

- Glue 4.0 + Iceberg + GlueCatalog pattern
- Must manually register named catalog via `SparkSession.builder.config()`
- Read with `spark.table("glue_catalog.db.table")` — NOT `spark.read.format("iceberg").load()`
- Write with `df.writeTo("glue_catalog.db.table").using("iceberg").createOrReplace()`
- Workflow: `datalake-medallion-{env}` (ON_DEMAND trigger)

## AWS Environment

- **Account**: 445985103066
- **Region**: us-east-1
- **SSO Portal**: https://mayadangelou.awsapps.com/start
- **AWS Profile**: `data-lake`
- **S3 State Bucket**: `mayadangelou-datalake-tfstate`
- **DynamoDB Lock Table**: `datalake-tfstate-lock`

## Common Debugging

### Connector shows RUNNING but no data flowing

1. Check connector logs: `task reviewer:connector-logs FILTER=ERROR`
2. Check replication slot is active: `task reviewer:cdc-status`
3. Check topics have data: `task reviewer:topics` (partitions > 0)
4. Check S3 freshness: `task reviewer:s3-freshness`
5. Wait for commit interval (120s) before concluding sink is broken

### Terraform plan shows unexpected changes

- Verify correct workspace: `terraform workspace show` inside the stack directory
- Check `locals.tf` in the stack for workspace-conditional config
- Cross-stack outputs may have changed — re-init dependent stacks

### Athena query fails with AccessDeniedException

- Lake Formation ABAC is enforced — check role's LF-Tag grants
- DataAnalyst cannot access MNPI databases
- FinanceAnalyst cannot access raw layer
- Use `data-engineers-{env}` workgroup for full access

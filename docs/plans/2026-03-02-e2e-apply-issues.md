# E2E Deploy Issues Analysis

> Captured during prod destroy/rebuild cycle on 2026-03-02

## Summary

A full `terraform destroy` + `terraform apply` cycle for the prod workspace revealed **7 distinct issues** that prevented a clean single-command `terraform apply`. The deploy required **5 manual interventions** and **4 separate apply runs** to complete ~190 resources.

---

## Issue 1: `count` Depends on Unknown Resource Attributes

**Severity**: Blocks entire apply on fresh deploy
**Root cause**: Two modules use `count` conditions that reference outputs from other modules:

```hcl
# modules/service-roles/main.tf:216
count = var.aurora_secret_arn != "" ? 1 : 0

# modules/observability/main.tf:421
count = var.enable_quicksight && var.quicksight_kms_key_arn != "" ? 1 : 0
```

On a fresh deploy, `aurora_secret_arn` comes from `module.aurora_postgres` which hasn't been created yet. Terraform can't evaluate the `count` expression during planning because the value is `(known after apply)`.

**Workaround used**: Phased apply with `-target`:
1. First: networking, data-lake-storage, streaming, identity-center
2. Second: aurora-postgres (creates the secret)
3. Third: full apply (all `count` values now known)

**Proper fix options**:
- **A) Terragrunt**: Split into separate state files with explicit dependency ordering (see brainstorm)
- **B) Remove count conditions**: Make the IAM policies unconditional (they're harmless when Aurora doesn't exist — policies referencing nonexistent secrets don't cause errors)
- **C) Use `try()` with a sentinel**: `count = try(var.aurora_secret_arn, "") != "" ? 1 : 0` (doesn't actually fix the unknown-at-plan issue)

---

## Issue 2: Secrets Manager 7-Day Recovery Window

**Severity**: Blocks Aurora recreation after destroy
**Root cause**: When `terraform destroy` deletes a Secrets Manager secret, AWS places it in a 7-day recovery window. Recreating a secret with the same name fails:

```
You can't create this secret because a secret with this name
is already scheduled for deletion.
```

**Workaround used**: Force-delete before re-apply:
```bash
aws secretsmanager delete-secret \
  --secret-id "datalake/aurora/prod/master-password" \
  --force-delete-without-recovery
```

**Proper fix options**:
- **A) Add `recovery_window_in_days = 0`** to the secret resource (disables recovery window, secret deleted immediately). Trade-off: no safety net for accidental deletions.
- **B) Use unique names**: Append a random suffix (e.g., timestamp) so names never collide. Trade-off: harder to find secrets manually.
- **C) Terragrunt + separate state**: Aurora module destroys independently, handles its own lifecycle.

---

## Issue 3: QuickSight Standard Edition Can't Be Destroyed

**Severity**: Recurring — every apply attempts to create/delete, fails
**Root cause**: The `aws_quicksight_account_subscription` resource only supports deletion for Enterprise edition. Standard edition returns:

```
PreconditionNotMetException: Failed to unsubscribe as the account
is not an Enterprise account.
```

Additionally, importing the existing subscription triggers a ForceNew replacement because `authentication_method` isn't populated on import, causing a destroy+create cycle that always fails.

**Workaround used**: Remove from state after each apply:
```bash
terraform state rm 'module.observability.aws_quicksight_account_subscription.this[0]'
```

**Proper fix options**:
- **A) Add lifecycle `prevent_destroy = true`** + manual initial creation
- **B) Remove from Terraform entirely**: Create QuickSight subscription manually or via a one-time script, manage only the IAM policies and data source in TF
- **C) Use a `data` source** instead of a resource to reference the existing subscription

---

## Issue 4: MSK Connect Plugin JARs Not in S3

**Severity**: Blocks MSK Connect module
**Root cause**: The MSK Connect custom plugin resources reference S3 objects (Debezium ZIP, Iceberg ZIP) that must be uploaded before Terraform can create the plugins. This is an out-of-band dependency — the JARs are built from source and uploaded by `scripts/upload-connector-plugins.sh`.

**Workaround used**: Run upload script between apply phases.

**Proper fix options**:
- **A) Terragrunt dependency**: MSK Connect module depends on a "plugins" module that runs the upload script as a `null_resource` with `local-exec`
- **B) Terraform `null_resource`**: Add a provisioner that downloads and uploads JARs as part of the plan
- **C) Accept as post-deploy step**: Document the ordering requirement (current approach)

---

## Issue 5: Debezium Connector Fails Without CDC Init

**Severity**: Connector enters FAILED state, requires manual cleanup
**Root cause**: The Debezium source connector expects a PostgreSQL replication slot and publication to exist. Without them, the connector task fails immediately. The CDC init (`scripts/init-aurora-cdc.sh`) must run before the connector is created.

**Workaround used**:
1. Remove failed connector from state
2. Delete failed connector from AWS
3. Run CDC init script
4. Re-apply to create connector

**Proper fix options**:
- **A) Terragrunt dependency**: CDC init as a separate component that runs between Aurora and MSK Connect
- **B) Feature flag**: Keep `enable_debezium_connector = false` by default, set to `true` only after CDC init
- **C) `null_resource` with CDC init**: Run the init script as part of the Terraform apply (but requires RDS Data API access from the machine running Terraform)

---

## Issue 6: Iceberg Sink Connector Missing AWS Region

**Severity**: Connector RUNNING but tasks FAILED (silent failure)
**Root cause**: MSK Connect workers don't expose `AWS_REGION` as an environment variable. The Iceberg sink's S3FileIO uses the AWS SDK v2 region provider chain, which fails because:
1. No `AWS_REGION` env var
2. No AWS profile configured
3. No EC2 instance metadata (MSK Connect workers aren't EC2 instances)

The connector shows as RUNNING at the MSK Connect level, but the individual task fails at `IcebergSinkTask.open()` with:
```
SdkClientException: Unable to load region from any of the providers in the chain
```

**Fix applied**: Added `"iceberg.catalog.client.region" = data.aws_region.current.name` to connector config.

**Lesson**: MSK Connect connectors can report RUNNING while all tasks are FAILED. Always check CloudWatch logs, not just connector state.

---

## Issue 7: S3 Bucket DENY Policy Blocks Destroy

**Severity**: Minor — buckets with objects can't be destroyed
**Root cause**: Non-empty S3 buckets fail `terraform destroy` with `BucketNotEmpty`. The DENY bucket policies also complicate manual cleanup since only allowed IAM roles can delete objects.

**Workaround used**: `aws s3 rm s3://bucket-name --recursive` before targeted destroy.

**Proper fix options**:
- **A) Add `force_destroy = true`** to S3 bucket resources (Terraform empties bucket before deleting)
- **B) Terragrunt**: Separate storage module with its own lifecycle
- **C) Accept as expected behavior**: Data buckets shouldn't be easily destroyable in production

---

## Dependency Chain Analysis

The current module dependency graph (implicit through variable passing):

```
networking ──────────────────────────────────┐
data_lake_storage ──────────────────────┐    │
identity_center ────────────────────┐   │    │
                                    │   │    │
streaming (MSK) ◄───────────────────┼───┼────┘  (needs VPC, subnets, SGs)
                                    │   │
aurora_postgres ◄───────────────────┼───┼────── (needs VPC, subnets, SGs)
                                    │   │
service_roles ◄─────────────────────┼───┘  (needs KMS ARNs, bucket ARNs, secret ARN*)
                                    │
glue_catalog ◄──────────────────────┼───── (needs bucket IDs)
                                    │
lake_formation ◄────────────────────┼───── (needs IC groups, databases, buckets, Glue role)
                                    │
analytics (Athena) ◄────────────────┼───── (needs bucket ARN for query results)
                                    │
observability ◄─────────────────────┼───── (needs KMS ARNs*, bucket ARNs)
                                    │
glue_etl ◄─────────────────────────────── (needs Glue role, scripts bucket)
                                    │
lambda_producer ◄───────────────────┼───── (needs VPC, subnets, MSK brokers, Aurora endpoint)
                                    │
msk_connect ◄──────────────────────────── (needs MSK, VPC, Aurora, IAM role, plugins*)

* = creates the "unknown at plan time" dependency that blocks single-pass apply
```

**Critical path bottleneck**: `aurora_postgres.secret_arn` → `service_roles.kafka_connect_secrets` count

**Out-of-band dependencies** (not in Terraform):
- MSK Connect plugins (S3 upload script)
- Aurora CDC init (replication slot + publication + tables)
- QuickSight subscription (pre-existing, unmanageable by TF)
- Lambda deployment artifact (build script)

---

## Time Breakdown

| Phase | Duration | Resources |
|-------|----------|-----------|
| Destroy (with workarounds) | ~15 min | -190 → 0 |
| Wait | 5 min | — |
| Phase 1: networking + storage + MSK + IC | ~30 min | +80 |
| Phase 2: Aurora targeted | ~11 min | +6 |
| Phase 3: Full apply (remaining) | ~20 min | +100 |
| Upload connector plugins | ~2 min | — |
| Aurora CDC init | ~1 min | — |
| Fix Debezium connector | ~15 min | +1 |
| Fix Iceberg region config | ~8 min | replace 2 |
| **Total rebuild** | **~107 min** | **~190 resources** |

A clean single-command `terraform apply` should take ~45 minutes (MSK 28min + Aurora 10min + connectors 15min in parallel). The extra ~60 minutes came from manual interventions.

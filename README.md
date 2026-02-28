# Data Lake Platform

Secure, auditable AWS Data Lake with MNPI/non-MNPI isolation for an asset management firm.

## Prerequisites

- [Terraform](https://terraform.io) >= 1.7.0
- [Kind](https://kind.sigs.k8s.io/) >= 0.20
- [Tilt](https://tilt.dev/) >= 0.33
- [Task](https://taskfile.dev/) >= 3.0
- [kubectl](https://kubernetes.io/docs/tasks/tools/) >= 1.28
- [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age)
- AWS CLI v2 with SSO configured

## Quick Start

```bash
task up          # Bootstrap Kind + ArgoCD + deploy workloads
task status      # Check all resources
task down        # Tear down everything
```

## Architecture

See [Architecture Design](docs/plans/2026-02-28-data-lake-platform-design.md) for full details.

## Project Structure

- `terraform/local/` — Kind cluster + ArgoCD bootstrap (GitOps bridge)
- `terraform/aws/` — AWS infrastructure modules + environments
- `strimzi/` — Kafka Connect (Debezium CDC + Iceberg sinks)
- `sample-postgres/` — Source RDBMS for CDC demo
- `scripts/` — SQL transforms and validation queries
- `docs/` — Architecture docs and plans

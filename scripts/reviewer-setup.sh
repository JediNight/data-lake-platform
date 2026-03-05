#!/usr/bin/env bash
# scripts/reviewer-setup.sh
# Interactive reviewer onboarding — installs tools, authenticates, and deploys.
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────
PROFILE_NAME="data-lake"
SSO_START_URL="https://mayadangelou.awsapps.com/start"
SSO_REGION="us-east-1"
SSO_ACCOUNT_ID="445985103066"
SSO_ROLE_NAME="Reviewer"
AWS_REGION="us-east-1"
# ───────────────────────────────────────────────────────────────────────

# ── Colors & Helpers ──────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'

step_num=0
step() {
  step_num=$((step_num + 1))
  echo ""
  echo -e "${CYAN}${BOLD}[$step_num] $1${RESET}"
  echo -e "${DIM}$(printf '%.0s─' {1..60})${RESET}"
}

ok()   { echo -e "    ${GREEN}✓${RESET} $1"; }
warn() { echo -e "    ${YELLOW}!${RESET} $1"; }
fail() { echo -e "    ${RED}✗${RESET} $1"; }
info() { echo -e "    ${DIM}$1${RESET}"; }

CHOICE=0  # global — set by prompt_choice
prompt_choice() {
  local question="$1"
  shift
  local options=("$@")
  echo ""
  echo -e "  ${BOLD}${question}${RESET}"
  echo ""
  for i in "${!options[@]}"; do
    echo -e "    ${CYAN}$((i+1)))${RESET} ${options[$i]}"
  done
  echo ""
  while true; do
    echo -ne "  ${BOLD}Enter choice [1-${#options[@]}]: ${RESET}"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
      CHOICE=$((choice - 1))
      return 0
    fi
    echo -e "  ${RED}Invalid choice. Try again.${RESET}"
  done
}
# ───────────────────────────────────────────────────────────────────────

clear 2>/dev/null || true

echo ""
echo -e "${BOLD}"
cat << 'BANNER'
    ┌──────────────────────────────────────────────────────┐
    │                                                      │
    │      ██████╗  █████╗ ████████╗ █████╗                │
    │      ██╔══██╗██╔══██╗╚══██╔══╝██╔══██╗               │
    │      ██║  ██║███████║   ██║   ███████║               │
    │      ██║  ██║██╔══██║   ██║   ██╔══██║               │
    │      ██████╔╝██║  ██║   ██║   ██║  ██║               │
    │      ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝               │
    │              L A K E   P L A T F O R M               │
    │                                                      │
    │   Secure CDC + Streaming Data Lake on AWS            │
    │   MNPI-isolated · Iceberg · Medallion Architecture   │
    │                                                      │
    └──────────────────────────────────────────────────────┘
BANNER
echo -e "${RESET}"
echo -e "  ${DIM}This script will set up everything you need to review the platform.${RESET}"
echo -e "  ${DIM}Takes about 5 minutes — mostly waiting for SSO and tool downloads.${RESET}"

# =====================================================================
# Step 1: Install mise + project tools
# =====================================================================
step "Tool Installation"

if command -v mise &>/dev/null; then
  ok "mise $(mise --version | awk '{print $1}') already installed"
elif [ -x "$HOME/.local/bin/mise" ]; then
  export PATH="$HOME/.local/bin:$PATH"
  ok "mise $(mise --version | awk '{print $1}') found at ~/.local/bin/mise"
else
  info "mise not found — installing (https://mise.jdx.dev)..."
  curl -fsSL https://mise.run | sh 2>&1 | tail -1
  export PATH="$HOME/.local/bin:$PATH"
  ok "mise $(mise --version | awk '{print $1}') installed"
fi

echo ""
info "Installing project tools from mise.toml..."
info "terraform 1.9.8, aws-cli 2, kind, kubectl, helm, kustomize, tilt, sops, age, task"
echo ""
mise trust --quiet 2>/dev/null || true
mise install 2>&1 | sed 's/^/    /'
eval "$(mise activate bash)"

echo ""
TOOLS_OK=true
for tool in terraform aws kind kubectl helm kustomize tilt task sops; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool $(command -v "$tool" | xargs basename)"
  else
    fail "$tool NOT FOUND"
    TOOLS_OK=false
  fi
done

if [ "$TOOLS_OK" = false ]; then
  echo ""
  fail "Some tools failed to install. Check the output above."
  echo -e "    Try: ${CYAN}mise install --verbose${RESET}"
  exit 1
fi

# =====================================================================
# Step 2: AWS SSO Configuration
# =====================================================================
step "AWS Authentication"

mkdir -p ~/.aws
CONFIG_FILE="${HOME}/.aws/config"

if grep -q "\[profile ${PROFILE_NAME}\]" "$CONFIG_FILE" 2>/dev/null; then
  ok "AWS profile '${PROFILE_NAME}' already configured"
else
  cat >> "$CONFIG_FILE" << EOF

[profile ${PROFILE_NAME}]
sso_start_url = ${SSO_START_URL}
sso_region = ${SSO_REGION}
sso_account_id = ${SSO_ACCOUNT_ID}
sso_role_name = ${SSO_ROLE_NAME}
region = ${AWS_REGION}
output = json
EOF
  ok "Created AWS profile '${PROFILE_NAME}'"
fi

echo ""
echo -e "    ${DIM}┌─────────────────────────────────────────┐${RESET}"
echo -e "    ${DIM}│${RESET}  Portal:  ${CYAN}${SSO_START_URL}${RESET}"
echo -e "    ${DIM}│${RESET}  Account: ${SSO_ACCOUNT_ID}"
echo -e "    ${DIM}│${RESET}  Role:    ${SSO_ROLE_NAME}"
echo -e "    ${DIM}│${RESET}  Region:  ${AWS_REGION}"
echo -e "    ${DIM}└─────────────────────────────────────────┘${RESET}"

# Check if already logged in
if aws sts get-caller-identity --profile "${PROFILE_NAME}" &>/dev/null 2>&1; then
  ok "Already authenticated"
  IDENTITY=$(aws sts get-caller-identity --profile "${PROFILE_NAME}" --query 'Arn' --output text)
  info "Identity: ${IDENTITY}"
else
  echo ""
  echo -e "    ${YELLOW}Opening browser for SSO login...${RESET}"
  echo -e "    ${BOLD}Sign in with the credentials from the submission notes.${RESET}"
  echo ""
  aws sso login --profile "${PROFILE_NAME}"

  if aws sts get-caller-identity --profile "${PROFILE_NAME}" &>/dev/null 2>&1; then
    ok "Login successful"
  else
    fail "Login failed"
    echo -e "    Try manually: ${CYAN}aws sso login --profile ${PROFILE_NAME}${RESET}"
    exit 1
  fi
fi

# =====================================================================
# Step 3: Quick infrastructure health check
# =====================================================================
step "Infrastructure Health Check"

info "Checking what's already running..."
echo ""

CONNECTORS=$(AWS_PROFILE="${PROFILE_NAME}" aws kafkaconnect list-connectors \
  --query 'length(connectors[?connectorState==`RUNNING`])' --output text 2>/dev/null || echo "0")
GLUE_JOBS=$(AWS_PROFILE="${PROFILE_NAME}" aws glue get-jobs \
  --query 'length(Jobs)' --output text 2>/dev/null || echo "0")
LAMBDA=$(AWS_PROFILE="${PROFILE_NAME}" aws lambda get-function \
  --function-name datalake-trading-simulator-prod \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || echo "")

if [ "$CONNECTORS" -ge 3 ] 2>/dev/null && [ "$GLUE_JOBS" -ge 4 ] 2>/dev/null && [ -n "$LAMBDA" ]; then
  ok "MSK Connect:  ${CONNECTORS}/3 connectors RUNNING"
  ok "Glue ETL:     ${GLUE_JOBS}/4 jobs deployed"
  ok "Lambda:       ${LAMBDA} active"
  PROD_DEPLOYED=true
else
  warn "MSK Connect:  ${CONNECTORS}/3 connectors"
  warn "Glue ETL:     ${GLUE_JOBS}/4 jobs"
  if [ -n "$LAMBDA" ]; then ok "Lambda: ${LAMBDA}"; else warn "Lambda: not deployed"; fi
  PROD_DEPLOYED=false
fi

# =====================================================================
# Step 4: What would you like to do?
# =====================================================================
step "Choose Your Adventure"

if [ "$PROD_DEPLOYED" = true ]; then
  echo -e "    ${GREEN}Production is fully deployed and healthy.${RESET}"
  echo ""
fi

echo -e "    ${BOLD}The platform runs in two modes:${RESET}"
echo ""
echo -e "    ${CYAN}Local Dev${RESET} ${DIM}(Kind + Strimzi + ArgoCD on your laptop)${RESET}"
echo -e "    ${DIM}    Mirrors the full prod pipeline locally. Two CronJobs generate${RESET}"
echo -e "    ${DIM}    trading data every minute into PostgreSQL. Debezium captures CDC${RESET}"
echo -e "    ${DIM}    events, streams them through Kafka, and Iceberg sinks write${RESET}"
echo -e "    ${DIM}    Parquet files to S3. ArgoCD watches the local git repo — commit${RESET}"
echo -e "    ${DIM}    a change and it auto-syncs. Same GitOps flow as a real cluster.${RESET}"
echo -e "    ${DIM}    Requires: Docker Desktop running with ~8GB RAM allocated.${RESET}"
echo ""
echo -e "    ${CYAN}Production${RESET} ${DIM}(fully managed AWS — Lambda, MSK, Aurora, Glue)${RESET}"
echo -e "    ${DIM}    No Kubernetes, no containers to manage. Lambda generates trading${RESET}"
echo -e "    ${DIM}    data, Aurora stores it, Debezium captures CDC via MSK Connect,${RESET}"
echo -e "    ${DIM}    Iceberg sinks land Parquet in S3, and Glue ETL runs the medallion${RESET}"
echo -e "    ${DIM}    transforms (raw → curated → analytics). Query via Athena.${RESET}"
echo -e "    ${DIM}    ~200 resources across 6 Terraform stacks. Already deployed.${RESET}"

prompt_choice "What would you like to do?" \
  "Explore production (query data, check pipeline health — already deployed)" \
  "Spin up local dev environment (~15 min, needs Docker)" \
  "Deploy production from scratch (~25-30 min, creates ~200 AWS resources)" \
  "Exit (come back later)"

case $CHOICE in
  0)
    # ── Explore production ──
    step "Production Explorer"

    echo -e "    ${BOLD}Checking pipeline health...${RESET}"
    echo ""
    task reviewer:verify 2>&1 | sed 's/^/    /'

    echo ""
    echo -e "  ${DIM}$(printf '%.0s─' {1..60})${RESET}"
    echo ""
    echo -e "  ${BOLD}Useful commands to explore:${RESET}"
    echo ""
    echo -e "    ${CYAN}task athena:demo${RESET}              Query all medallion layers via Athena"
    echo -e "    ${CYAN}task reviewer:e2e${RESET}             End-to-end pipeline test (~3 min)"
    echo -e "    ${CYAN}task reviewer:sample-queries${RESET}  Row counts across all 8 tables"
    echo -e "    ${CYAN}task reviewer:kafka-status${RESET}    MSK cluster + connector health"
    echo -e "    ${CYAN}task reviewer:cdc-status${RESET}      Aurora replication slot + WAL lag"
    echo -e "    ${CYAN}task reviewer:s3-freshness${RESET}    Latest Iceberg data files per table"
    echo -e "    ${CYAN}task reviewer:connector-logs${RESET}  Tail connector logs (FILTER=ERROR)"
    ;;

  1)
    # ── Local dev ──
    step "Local Dev Deployment"

    echo -e "    ${BOLD}This will:${RESET}"
    echo -e "    ${DIM}  1. Deploy all Terraform stacks in dev workspace         (~5 min)${RESET}"
    echo -e "    ${DIM}     Creates Kind cluster, S3 buckets, Glue databases${RESET}"
    echo -e "    ${DIM}  2. Install ArgoCD + Strimzi Kafka operator               (~2 min)${RESET}"
    echo -e "    ${DIM}  3. Build & load container images into Kind                (~3 min)${RESET}"
    echo -e "    ${DIM}     Kafka Connect (with Iceberg JARs) + Producer API${RESET}"
    echo -e "    ${DIM}  4. ArgoCD syncs all apps from local git repo              (~5 min)${RESET}"
    echo -e "    ${DIM}     PostgreSQL, Debezium CDC, Iceberg sinks, Producer API${RESET}"
    echo -e "    ${DIM}  5. CronJobs generate trading data every minute${RESET}"
    echo ""
    echo -e "    ${YELLOW}Requires Docker Desktop running with ~8GB RAM.${RESET}"
    echo -e "    ${YELLOW}Total time: ~15 minutes (ArgoCD sync is the bottleneck).${RESET}"
    echo ""
    echo -ne "  ${BOLD}Continue? [y/N]: ${RESET}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      echo ""
      task dev:up 2>&1 | sed 's/^/    /'

      echo ""
      echo -e "  ${DIM}$(printf '%.0s─' {1..60})${RESET}"
      echo ""
      echo -e "  ${BOLD}Local dev is running. Useful commands:${RESET}"
      echo ""
      echo -e "    ${CYAN}task dev:status${RESET}              Cluster health (pods, apps, connectors)"
      echo -e "    ${CYAN}task dev:tilt${RESET}                Start Tilt for hot-reload dev loop"
      echo -e "    ${CYAN}task dev:refresh-creds${RESET}       Re-encrypt AWS creds after SSO refresh"
      echo -e "    ${CYAN}task dev:down${RESET}                Tear everything down"
      echo ""
      echo -e "    ${CYAN}ArgoCD UI:${RESET}  http://localhost:8080"
      echo -e "    ${DIM}  user: admin / pass: datalake-admin${RESET}"
    else
      info "Skipped. Run anytime with: task dev:up"
    fi
    ;;

  2)
    # ── Deploy production ──
    step "Production Deployment"

    echo -e "    ${BOLD}This will create ~200 AWS resources across 6 Terraform stacks:${RESET}"
    echo ""
    echo -e "    ${DIM}  Tier 0: account-baseline (Identity Center, LF settings)          (~1 min)${RESET}"
    echo -e "    ${DIM}  Tier 1: foundation (VPC) + data-lake-core (S3, KMS, Glue)        (~3 min)  [parallel]${RESET}"
    echo -e "    ${DIM}  Tier 2: security (Lake Formation) + compute (MSK, Aurora)        (~15 min)  [parallel]${RESET}"
    echo -e "    ${DIM}          ↑ MSK cluster ~15 min, Aurora ~10 min — this is the bottleneck${RESET}"
    echo -e "    ${DIM}  Tier 3: pipelines (MSK Connect, Lambda, Glue ETL, Athena)        (~8 min)${RESET}"
    echo -e "    ${DIM}          ↑ Downloads connector JARs, uploads to S3, provisions 3 connectors${RESET}"
    echo ""
    echo -e "    ${DIM}  Aurora CDC (replication slot + publication) initialized automatically.${RESET}"
    echo -e "    ${DIM}  Glue medallion workflow triggered after deployment.${RESET}"
    echo ""
    echo -e "    ${YELLOW}Total time: ~25-30 minutes (MSK and Aurora provisioning are the bottleneck).${RESET}"
    echo ""
    echo -ne "  ${BOLD}Continue? [y/N]: ${RESET}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      echo ""
      task deploy:all WORKSPACE=prod 2>&1 | sed 's/^/    /'

      echo ""
      echo -e "  ${DIM}$(printf '%.0s─' {1..60})${RESET}"
      echo ""
      echo -e "  ${BOLD}Production deployed. Verify with:${RESET}"
      echo ""
      echo -e "    ${CYAN}task reviewer:verify${RESET}          Full infrastructure status"
      echo -e "    ${CYAN}task reviewer:e2e${RESET}             End-to-end pipeline test (~3 min)"
      echo -e "    ${CYAN}task athena:demo${RESET}              Query all medallion layers"
    else
      info "Skipped. Run anytime with: task deploy:all WORKSPACE=prod"
    fi
    ;;

  3)
    # ── Exit ──
    echo ""
    info "No worries. Here's the cheat sheet for later:"
    echo ""
    echo -e "    ${CYAN}./scripts/reviewer-setup.sh${RESET}    Run this script again"
    echo -e "    ${CYAN}task dev:up${RESET}                    Spin up local dev environment"
    echo -e "    ${CYAN}task deploy:all WORKSPACE=prod${RESET} Deploy production from scratch"
    echo -e "    ${CYAN}task reviewer:verify${RESET}           Check infrastructure health"
    echo -e "    ${CYAN}task athena:demo${RESET}               Query data across all layers"
    ;;
esac

# =====================================================================
# Done
# =====================================================================
echo ""
echo -e "${BOLD}"
cat << 'FOOTER'
    ┌──────────────────────────────────────────────────────┐
    │                                                      │
    │   Setup complete. Happy reviewing!                   │
    │                                                      │
    │   Docs:  docs/REVIEWER_GUIDE.md                      │
    │          docs/documentation.md                        │
    │                                                      │
    └──────────────────────────────────────────────────────┘
FOOTER
echo -e "${RESET}"

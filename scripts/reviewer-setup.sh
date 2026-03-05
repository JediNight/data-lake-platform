#!/usr/bin/env bash
# scripts/reviewer-setup.sh
# One-command reviewer onboarding: configures AWS SSO profile and logs in.
#
# Usage: ./scripts/reviewer-setup.sh
#
# This script:
#   1. Checks that aws CLI is installed
#   2. Writes an SSO profile to ~/.aws/config (idempotent)
#   3. Opens a browser for SSO login
#   4. Verifies credentials work
#
# The SSO portal will prompt for username/password — use the credentials
# from the submission notes.
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────
PROFILE_NAME="data-lake"
SSO_START_URL="https://mayadangelou.awsapps.com/start"
SSO_REGION="us-east-1"
SSO_ACCOUNT_ID="445985103066"
SSO_ROLE_NAME="Reviewer"
AWS_REGION="us-east-1"
# ───────────────────────────────────────────────────────────────────────

echo "================================================"
echo "  Data Lake Platform — Reviewer Setup"
echo "================================================"
echo ""

# Step 1: Check aws CLI exists
if ! command -v aws &>/dev/null; then
  echo "ERROR: AWS CLI not found."
  echo ""
  echo "Install with mise (recommended):"
  echo "  curl https://mise.jdx.dev/install.sh | sh"
  echo "  mise install"
  echo ""
  echo "Or install manually:"
  echo "  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi
echo "AWS CLI: $(aws --version | head -1)"
echo ""

# Step 2: Write SSO profile to ~/.aws/config
mkdir -p ~/.aws
CONFIG_FILE="${HOME}/.aws/config"

if grep -q "\[profile ${PROFILE_NAME}\]" "$CONFIG_FILE" 2>/dev/null; then
  echo "Profile '${PROFILE_NAME}' already exists in ${CONFIG_FILE}."
  echo "Skipping config — using existing profile."
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
  echo "Created AWS profile '${PROFILE_NAME}' in ${CONFIG_FILE}"
fi

echo ""
echo "--- SSO Configuration ---"
echo "  Profile:   ${PROFILE_NAME}"
echo "  Portal:    ${SSO_START_URL}"
echo "  Account:   ${SSO_ACCOUNT_ID}"
echo "  Role:      ${SSO_ROLE_NAME}"
echo "  Region:    ${AWS_REGION}"
echo ""

# Step 3: SSO Login
echo "Opening browser for SSO login..."
echo "Sign in with the credentials from the submission notes."
echo ""
aws sso login --profile "${PROFILE_NAME}"

# Step 4: Verify
echo ""
echo "--- Verifying Access ---"
if aws sts get-caller-identity --profile "${PROFILE_NAME}" &>/dev/null; then
  aws sts get-caller-identity --profile "${PROFILE_NAME}" --output table
  echo ""
  echo "================================================"
  echo "  Setup complete!"
  echo "================================================"
  echo ""
  echo "Next steps:"
  echo "  task reviewer:verify          # Full infrastructure status"
  echo "  task reviewer:e2e             # End-to-end pipeline test (~3 min)"
  echo "  task reviewer:kafka-status    # MSK cluster + connector health"
  echo "  task athena:demo              # Query all medallion layers"
else
  echo "ERROR: Login failed. Please try again:"
  echo "  aws sso login --profile ${PROFILE_NAME}"
  exit 1
fi

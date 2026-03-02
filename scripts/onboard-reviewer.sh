#!/usr/bin/env bash
# onboard-reviewer.sh — Add a reviewer to IAM Identity Center
#
# Creates an IC user with the given email and adds them to all 3 persona
# groups (FinanceAnalysts, DataAnalysts, DataEngineers). The user receives
# an email invitation to set their password and access the SSO portal.
#
# Usage:
#   ./scripts/onboard-reviewer.sh reviewer@example.com "First" "Last"
#
# After running:
#   1. Reviewer checks email for IC invitation
#   2. Sets password via the link
#   3. Logs in at: https://mayadangelou.awsapps.com/start
#   4. Picks a role (FinanceAnalyst, DataAnalyst, or DataEngineer)
#   5. Opens Athena in the AWS console to run queries
#
# To remove:
#   ./scripts/onboard-reviewer.sh --remove reviewer@example.com

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-data-lake}"
IDENTITY_STORE_ID="d-9066032f16"

# Group IDs (from terraform identity-center module)
FINANCE_ANALYSTS_GROUP="8438e498-d061-7088-5eb3-f891ed96ad73"
DATA_ANALYSTS_GROUP="c4a8a468-20f1-7082-f7d5-a657af4eebb9"
DATA_ENGINEERS_GROUP="54c82418-60c1-70a9-9070-b3f2d55d2618"

usage() {
  echo "Usage:"
  echo "  $0 <email> <first-name> <last-name>    # Add reviewer"
  echo "  $0 --remove <email>                     # Remove reviewer"
  echo ""
  echo "Example:"
  echo "  $0 reviewer@company.com John Doe"
  exit 1
}

get_user_id_by_email() {
  local email="$1"
  AWS_PROFILE="$AWS_PROFILE" aws identitystore list-users \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --filters "AttributePath=UserName,AttributeValue=${email}" \
    --query 'Users[0].UserId' --output text 2>/dev/null
}

add_to_group() {
  local user_id="$1"
  local group_id="$2"
  local group_name="$3"

  # Check if already a member
  existing=$(AWS_PROFILE="$AWS_PROFILE" aws identitystore list-group-memberships \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --group-id "$group_id" \
    --query "GroupMemberships[?MemberId.UserId=='${user_id}'].MembershipId" \
    --output text 2>/dev/null)

  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    echo "  Already in ${group_name}"
    return
  fi

  AWS_PROFILE="$AWS_PROFILE" aws identitystore create-group-membership \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --group-id "$group_id" \
    --member-id "UserId=${user_id}" > /dev/null

  echo "  Added to ${group_name}"
}

remove_from_group() {
  local user_id="$1"
  local group_id="$2"
  local group_name="$3"

  membership_id=$(AWS_PROFILE="$AWS_PROFILE" aws identitystore list-group-memberships \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --group-id "$group_id" \
    --query "GroupMemberships[?MemberId.UserId=='${user_id}'].MembershipId" \
    --output text 2>/dev/null)

  if [ -z "$membership_id" ] || [ "$membership_id" = "None" ]; then
    echo "  Not in ${group_name}, skipping"
    return
  fi

  AWS_PROFILE="$AWS_PROFILE" aws identitystore delete-group-membership \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --membership-id "$membership_id" > /dev/null

  echo "  Removed from ${group_name}"
}

# --- Remove mode ---
if [ "${1:-}" = "--remove" ]; then
  [ $# -lt 2 ] && usage
  email="$2"

  echo "Removing reviewer: ${email}"
  user_id=$(get_user_id_by_email "$email")

  if [ -z "$user_id" ] || [ "$user_id" = "None" ]; then
    echo "Error: User not found: ${email}"
    exit 1
  fi

  echo "Removing from groups..."
  remove_from_group "$user_id" "$FINANCE_ANALYSTS_GROUP" "FinanceAnalysts"
  remove_from_group "$user_id" "$DATA_ANALYSTS_GROUP" "DataAnalysts"
  remove_from_group "$user_id" "$DATA_ENGINEERS_GROUP" "DataEngineers"

  echo "Deleting user..."
  AWS_PROFILE="$AWS_PROFILE" aws identitystore delete-user \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --user-id "$user_id"

  echo "Done. Reviewer removed."
  exit 0
fi

# --- Add mode ---
[ $# -lt 3 ] && usage

email="$1"
first_name="$2"
last_name="$3"

echo "Onboarding reviewer: ${first_name} ${last_name} <${email}>"

# Check if user already exists
existing_id=$(get_user_id_by_email "$email")
if [ -n "$existing_id" ] && [ "$existing_id" != "None" ]; then
  echo "User already exists (ID: ${existing_id}), adding to groups..."
  user_id="$existing_id"
else
  echo "Creating IC user..."
  user_id=$(AWS_PROFILE="$AWS_PROFILE" aws identitystore create-user \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --user-name "$email" \
    --display-name "${first_name} ${last_name}" \
    --name "GivenName=${first_name},FamilyName=${last_name}" \
    --emails "Value=${email},Primary=true" \
    --query 'UserId' --output text)
  echo "Created user: ${user_id}"
fi

echo "Adding to groups..."
add_to_group "$user_id" "$FINANCE_ANALYSTS_GROUP" "FinanceAnalysts"
add_to_group "$user_id" "$DATA_ANALYSTS_GROUP" "DataAnalysts"
add_to_group "$user_id" "$DATA_ENGINEERS_GROUP" "DataEngineers"

echo ""
echo "================================================"
echo "  Reviewer onboarded successfully!"
echo "================================================"
echo ""
echo "Next steps for the reviewer:"
echo "  1. Check email for the IC invitation"
echo "  2. Click the link and set a password"
echo "  3. Log in at: https://mayadangelou.awsapps.com/start"
echo "  4. Select a role to test:"
echo "     - FinanceAnalyst  (MNPI + non-MNPI, curated + analytics)"
echo "     - DataAnalyst     (non-MNPI only, curated + analytics)"
echo "     - DataEngineer    (all zones, all layers, direct S3)"
echo "  5. Open Athena in the AWS console"
echo "  6. Select the matching workgroup:"
echo "     - finance-analysts-prod"
echo "     - data-analysts-prod"
echo "     - data-engineers-prod"
echo "  7. Try the sample queries from docs/documentation.md"
echo ""
echo "To remove this reviewer later:"
echo "  $0 --remove ${email}"

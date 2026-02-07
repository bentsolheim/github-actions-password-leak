#!/usr/bin/env bash
#
# reproduce.sh - Attempt to reproduce the GitHub Actions secret masking bug
#
# Theory: When a repository/environment secret is changed while a workflow is
# running, GitHub Actions may fail to mask the OLD secret value in the logs,
# causing it to appear in clear text.
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - Repository: bentsolheim/github-actions-password-leak (or set REPO below)
#
# Usage:
#   ./reproduce.sh
#   REPO=owner/repo WAIT=60 ./reproduce.sh

set -euo pipefail

REPO="${REPO:-bentsolheim/github-actions-password-leak}"
BRANCH="${BRANCH:-claude/reproduce-secrets-bug-ysKN2}"
WAIT="${WAIT:-30}"
SECRET_NAME="TEST_SECRET"
ORIGINAL_SECRET="original-secret-value-$(date +%s)"
CHANGED_SECRET="changed-secret-value-$(date +%s)"

echo "============================================"
echo "GitHub Actions Secret Masking Bug Reproducer"
echo "============================================"
echo ""
echo "Repository: $REPO"
echo "Branch:     $BRANCH"
echo "Secret:     $SECRET_NAME"
echo "Original:   $ORIGINAL_SECRET"
echo "Changed:    $CHANGED_SECRET"
echo "Wait time:  ${WAIT}s"
echo ""

# Step 1: Set the initial secret value
echo "[1/6] Setting initial secret value..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "$ORIGINAL_SECRET"
echo "  Secret set to: $ORIGINAL_SECRET"
echo ""

# Step 2: Trigger the workflow
echo "[2/6] Triggering workflow..."
gh workflow run secret-leak-test.yml \
  -R "$REPO" \
  --ref "$BRANCH" \
  -f "wait_seconds=$WAIT"
echo "  Workflow triggered. Waiting 5s for it to register..."
sleep 5
echo ""

# Step 3: Find the running workflow
echo "[3/6] Finding the workflow run..."
RUN_ID=""
for attempt in $(seq 1 12); do
  RUN_ID=$(gh run list \
    -R "$REPO" \
    -w "secret-leak-test.yml" \
    --branch "$BRANCH" \
    --status "in_progress" \
    --json databaseId \
    --jq '.[0].databaseId' 2>/dev/null || true)

  if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
    # Also check queued status
    RUN_ID=$(gh run list \
      -R "$REPO" \
      -w "secret-leak-test.yml" \
      --branch "$BRANCH" \
      --status "queued" \
      --json databaseId \
      --jq '.[0].databaseId' 2>/dev/null || true)
  fi

  if [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ]; then
    break
  fi

  echo "  Attempt $attempt/12: Workflow not found yet, waiting 5s..."
  sleep 5
done

if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
  echo "ERROR: Could not find the running workflow. Check manually:"
  echo "  gh run list -R $REPO -w secret-leak-test.yml"
  exit 1
fi

echo "  Found run: $RUN_ID"
echo "  URL: https://github.com/$REPO/actions/runs/$RUN_ID"
echo ""

# Step 4: Wait a bit, then change the secret while the workflow is running
CHANGE_DELAY=$((WAIT / 3))
if [ "$CHANGE_DELAY" -lt 5 ]; then
  CHANGE_DELAY=5
fi

echo "[4/6] Waiting ${CHANGE_DELAY}s before changing the secret..."
sleep "$CHANGE_DELAY"

echo "  Changing secret NOW!"
gh secret set "$SECRET_NAME" -R "$REPO" --body "$CHANGED_SECRET"
echo "  Secret changed to: $CHANGED_SECRET"
echo ""

# Step 5: Wait for the workflow to complete
echo "[5/6] Waiting for workflow to complete..."
gh run watch "$RUN_ID" -R "$REPO" --exit-status 2>/dev/null || true
echo "  Workflow completed."
echo ""

# Step 6: Check the logs for leaked secrets
echo "[6/6] Checking logs for leaked secrets..."
echo ""

LOG_FILE=$(mktemp)
gh run view "$RUN_ID" -R "$REPO" --log > "$LOG_FILE" 2>/dev/null || true

echo "--- Analysis ---"
echo ""

# Check if the original secret appears unmasked in the logs
ORIGINAL_FOUND=false
CHANGED_FOUND=false

if grep -q "$ORIGINAL_SECRET" "$LOG_FILE" 2>/dev/null; then
  ORIGINAL_FOUND=true
  echo "BUG REPRODUCED: Original secret found in clear text in logs!"
  echo "  Original secret: $ORIGINAL_SECRET"
  echo ""
  echo "  Matching lines:"
  grep -n "$ORIGINAL_SECRET" "$LOG_FILE" | head -20
  echo ""
else
  echo "Original secret NOT found in clear text (properly masked or not present)."
fi

echo ""

if grep -q "$CHANGED_SECRET" "$LOG_FILE" 2>/dev/null; then
  CHANGED_FOUND=true
  echo "NOTE: Changed secret also found in clear text in logs!"
  echo "  Changed secret: $CHANGED_SECRET"
  echo ""
  echo "  Matching lines:"
  grep -n "$CHANGED_SECRET" "$LOG_FILE" | head -20
  echo ""
else
  echo "Changed secret NOT found in clear text (expected - it was never used in the workflow)."
fi

echo ""
echo "============================================"
echo "                 RESULTS"
echo "============================================"
if $ORIGINAL_FOUND; then
  echo ""
  echo "  *** BUG REPRODUCED! ***"
  echo ""
  echo "  The original secret value appeared in clear text in the"
  echo "  workflow logs after being changed during the run."
  echo "  This confirms that GitHub Actions does not mask old"
  echo "  secret values once they are rotated."
  echo ""
else
  echo ""
  echo "  Bug NOT reproduced."
  echo ""
  echo "  The original secret was properly masked in the logs."
  echo "  You may want to try:"
  echo "    - Increasing WAIT time:  WAIT=120 ./reproduce.sh"
  echo "    - Running multiple times to catch a race condition"
  echo ""
fi
echo "============================================"
echo ""
echo "Full logs saved to: $LOG_FILE"
echo "Run URL: https://github.com/$REPO/actions/runs/$RUN_ID"

# Cleanup: reset the secret to a harmless value
echo ""
echo "Cleaning up: resetting secret to a dummy value..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "placeholder-rotate-me"
echo "Done."

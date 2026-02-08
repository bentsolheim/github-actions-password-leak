#!/usr/bin/env bash
#
# run-vulnerable.sh — A/B experiment: VULNERABLE workflow
#
# Runs the vulnerable workflow (no direct ${{ secrets.TEST_SECRET }} reference
# in the print job). The print job's masking dictionary never learns V1, so
# V1 leaks in cleartext after rotation.
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - Repository: bentsolheim/github-actions-password-leak (or set REPO)
#
# Usage:
#   ./run-vulnerable.sh
#   WAIT=60 ./run-vulnerable.sh

set -euo pipefail

REPO="${REPO:-bentsolheim/github-actions-password-leak}"
BRANCH="${BRANCH:-main}"
WAIT="${WAIT:-30}"
TIMESTAMP=$(date +%s)
SECRET_NAME="TEST_SECRET"
V1="cross-job-v1-${TIMESTAMP}"
V2="cross-job-v2-${TIMESTAMP}"
WORKFLOW="vulnerable.yml"

echo "============================================"
echo " A/B Experiment — Vulnerable Workflow"
echo "============================================"
echo ""
echo "Repository:  $REPO"
echo "Branch:      $BRANCH"
echo "V1 (before): $V1"
echo "V2 (after):  $V2"
echo "Wait time:   ${WAIT}s"
echo ""

# Step 1: Set secret to V1
echo "[1/6] Setting secret to V1..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "$V1"
sleep 2

# Step 2: Trigger workflow
echo "[2/6] Triggering workflow..."
gh workflow run "$WORKFLOW" \
  -R "$REPO" \
  --ref "$BRANCH" \
  -f "wait_seconds=$WAIT"
echo "  Waiting 5s for registration..."
sleep 5

# Step 3: Find the run
echo "[3/6] Finding workflow run..."
RUN_ID=""
for attempt in $(seq 1 24); do
  RUN_ID=$(gh run list \
    -R "$REPO" \
    -w "$WORKFLOW" \
    --branch "$BRANCH" \
    --status "in_progress" \
    --json databaseId \
    --jq '.[0].databaseId' 2>/dev/null || true)

  if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
    RUN_ID=$(gh run list \
      -R "$REPO" \
      -w "$WORKFLOW" \
      --branch "$BRANCH" \
      --status "queued" \
      --json databaseId \
      --jq '.[0].databaseId' 2>/dev/null || true)
  fi

  if [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ]; then
    break
  fi
  echo "  Attempt $attempt/24: waiting 5s..."
  sleep 5
done

if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
  echo "ERROR: Could not find the workflow run."
  exit 1
fi

echo "  Run: $RUN_ID"
echo "  URL: https://github.com/$REPO/actions/runs/$RUN_ID"

# Step 4: Rotate secret during capture job's wait window
echo "[4/6] Waiting for capture job to start, then rotating mid-sleep..."
while true; do
  CAPTURE_STATUS=$(gh run view "$RUN_ID" -R "$REPO" --json jobs \
    --jq '.jobs[] | select(.name == "capture") | .status' 2>/dev/null || true)
  if [ "$CAPTURE_STATUS" = "in_progress" ] || [ "$CAPTURE_STATUS" = "completed" ]; then
    break
  fi
  echo "  capture job status: ${CAPTURE_STATUS:-unknown}, waiting 5s..."
  sleep 5
done
# Give the encode step time to finish before we rotate
echo "  capture job is running. Waiting 15s for encode step to complete..."
sleep 15
echo "  Rotating secret to V2 (during capture job's sleep window)..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "$V2"
echo "  Rotated. Print job will get V2 in its masking dictionary."

# Step 5: Wait for workflow to complete
echo "[5/6] Waiting for workflow to complete..."
gh run watch "$RUN_ID" -R "$REPO" --exit-status 2>/dev/null || true
echo "  Done."

# Step 6: Analyze logs
echo "[6/6] Analyzing logs..."
LOG_FILE=$(mktemp)
gh run view "$RUN_ID" -R "$REPO" --log > "$LOG_FILE" 2>/dev/null || true

# Extract print job logs only
PRINT_LOG=$(mktemp)
grep "^print" "$LOG_FILE" > "$PRINT_LOG" 2>/dev/null || true

echo ""
echo "============================================"
echo " RESULTS"
echo "============================================"
echo ""

LEAKED=false

if grep -qF "$V1" "$PRINT_LOG" 2>/dev/null; then
  echo "  V1 in print job:  LEAKED"
  LEAKED=true
else
  echo "  V1 in print job:  MASKED"
fi

if grep -qF "$V2" "$PRINT_LOG" 2>/dev/null; then
  echo "  V2 in print job:  PRESENT (expected if masking V2)"
else
  echo "  V2 in print job:  NOT FOUND"
fi

echo ""
if [ "$LEAKED" = true ]; then
  echo "  RESULT: V1 LEAKED in cross-job output."
  echo "  The old secret value appeared unmasked in the print job."
else
  echo "  RESULT: V1 was masked. Leak not reproduced."
fi

echo ""
echo "Log file:  $LOG_FILE"
echo "Run URL:   https://github.com/$REPO/actions/runs/$RUN_ID"

# Cleanup
echo ""
echo "Cleaning up..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "placeholder-rotate-me"
rm -f "$PRINT_LOG"
echo "Done."

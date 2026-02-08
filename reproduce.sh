#!/usr/bin/env bash
#
# reproduce.sh - Cross-job secret leak via job outputs
#
# Demonstrates that rotating a secret between two jobs causes V1 to appear
# unmasked in the second job's logs. The second job's masking dict only
# knows V2, so V1 prints in cleartext.
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - Repository: bentsolheim/github-actions-password-leak (or set REPO)
#
# Usage:
#   ./reproduce.sh
#   WAIT=60 ./reproduce.sh

set -euo pipefail

REPO="${REPO:-bentsolheim/github-actions-password-leak}"
BRANCH="${BRANCH:-main}"
WAIT="${WAIT:-30}"
TIMESTAMP=$(date +%s)
SECRET_NAME="TEST_SECRET"
V1="cross-job-v1-${TIMESTAMP}"
V2="cross-job-v2-${TIMESTAMP}"
WORKFLOW="cross-job-secret-leak.yml"

echo "============================================"
echo " Cross-Job Secret Leak (Job Outputs)"
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

# Step 4: Wait for capture job to finish, then rotate
echo "[4/6] Waiting for capture job to complete before rotating..."
while true; do
  CAPTURE_STATUS=$(gh run view "$RUN_ID" -R "$REPO" --json jobs \
    --jq '.jobs[] | select(.name == "capture") | .status' 2>/dev/null || true)
  if [ "$CAPTURE_STATUS" = "completed" ]; then
    break
  fi
  echo "  capture job status: ${CAPTURE_STATUS:-unknown}, waiting 5s..."
  sleep 5
done
echo "  capture job completed. Rotating secret to V2..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "$V2"
echo "  Rotated."

# Step 5: Wait for workflow to complete
echo "[5/6] Waiting for workflow to complete..."
gh run watch "$RUN_ID" -R "$REPO" --exit-status 2>/dev/null || true
echo "  Done."

# Step 6: Analyze logs
echo "[6/6] Analyzing logs..."
LOG_FILE=$(mktemp)
gh run view "$RUN_ID" -R "$REPO" --log > "$LOG_FILE" 2>/dev/null || true

# Extract per-job logs
CAPTURE_LOG=$(mktemp)
PRINT_LOG=$(mktemp)
grep "^capture" "$LOG_FILE" > "$CAPTURE_LOG" 2>/dev/null || true
grep "^print" "$LOG_FILE" > "$PRINT_LOG" 2>/dev/null || true

# Check all four cells of the masking matrix
v1_in_capture="MASKED";  grep -qF "$V1" "$CAPTURE_LOG" 2>/dev/null && v1_in_capture="LEAKED"
v2_in_capture="MASKED";  grep -qF "$V2" "$CAPTURE_LOG" 2>/dev/null && v2_in_capture="LEAKED"
v1_in_print="MASKED";    grep -qF "$V1" "$PRINT_LOG"   2>/dev/null && v1_in_print="LEAKED"
v2_in_print="MASKED";    grep -qF "$V2" "$PRINT_LOG"   2>/dev/null && v2_in_print="LEAKED"

echo ""
echo "============================================"
echo " RESULTS — Masking Matrix"
echo "============================================"
echo ""
printf "  %-12s %-18s %-18s\n" "Job" "V1 (old secret)" "V2 (new secret)"
printf "  %-12s %-18s %-18s\n" "----------" "----------------" "----------------"
printf "  %-12s %-18s %-18s\n" "capture" "$v1_in_capture" "$v2_in_capture"
printf "  %-12s %-18s %-18s\n" "print" "$v1_in_print" "$v2_in_print"

echo ""
if [ "$v1_in_capture" = "MASKED" ] && [ "$v2_in_capture" = "MASKED" ] \
   && [ "$v1_in_print" = "LEAKED" ] && [ "$v2_in_print" = "MASKED" ]; then
  echo "  RESULT: Bug reproduced."
  echo "  V1 is correctly masked in the capture job but leaks in the print job"
  echo "  after secret rotation. V2 is masked everywhere."
elif [ "$v1_in_print" = "LEAKED" ]; then
  echo "  RESULT: V1 LEAKED in cross-job output."
  echo "  The old secret value appeared unmasked in the print job."
  echo "  (Some matrix cells differ from expected — see above.)"
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
rm -f "$CAPTURE_LOG" "$PRINT_LOG"
echo "Done."

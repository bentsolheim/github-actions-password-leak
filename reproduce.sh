#!/usr/bin/env bash
#
# reproduce.sh - Attempt to reproduce the GitHub Actions secret masking bug
#
# Theory: When a repository/environment secret is changed while a workflow is
# running, GitHub Actions may fail to mask the OLD secret value in the logs,
# causing it to appear in clear text.
#
# This script tests multiple scenarios:
#   1. Single-job rotation (original test)
#   2. Multi-job artifact handoff (V1 passed to job that only knows V2)
#   3. Continuous output during rotation (race condition surface)
#   4. Buffer flush before print (log chunk boundary)
#   5. Late rotation during print phase
#   6. GITHUB_OUTPUT step passing
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - Repository: bentsolheim/github-actions-password-leak (or set REPO below)
#
# Usage:
#   ./reproduce.sh
#   REPO=owner/repo WAIT=60 ./reproduce.sh
#   RAPID=1 ./reproduce.sh           # Rapid rotation mode (15 rotations)

set -euo pipefail

REPO="${REPO:-bentsolheim/github-actions-password-leak}"
BRANCH="${BRANCH:-main}"
WAIT="${WAIT:-60}"
RAPID="${RAPID:-0}"
TIMESTAMP=$(date +%s)
SECRET_NAME="TEST_SECRET"
ORIGINAL_SECRET="original-secret-value-${TIMESTAMP}"
CHANGED_SECRET="changed-secret-value-${TIMESTAMP}"

echo "============================================"
echo "GitHub Actions Secret Masking Bug Reproducer"
echo "============================================"
echo ""
echo "Repository:  $REPO"
echo "Branch:      $BRANCH"
echo "Secret:      $SECRET_NAME"
echo "Original:    $ORIGINAL_SECRET"
echo "Changed:     $CHANGED_SECRET"
echo "Wait time:   ${WAIT}s"
echo "Rapid mode:  $RAPID"
echo "Timestamp:   $TIMESTAMP"
echo ""

# Step 1: Set the initial secret value
echo "[1/7] Setting initial secret value..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "$ORIGINAL_SECRET"
echo "  Secret set to: $ORIGINAL_SECRET"
sleep 2
echo ""

# Step 2: Trigger the workflow
echo "[2/7] Triggering workflow..."
gh workflow run secret-leak-test.yml \
  -R "$REPO" \
  --ref "$BRANCH" \
  -f "wait_seconds=$WAIT"
echo "  Workflow triggered. Waiting 5s for it to register..."
sleep 5
echo ""

# Step 3: Find the running workflow
echo "[3/7] Finding the workflow run..."
RUN_ID=""
for attempt in $(seq 1 24); do
  RUN_ID=$(gh run list \
    -R "$REPO" \
    -w "secret-leak-test.yml" \
    --branch "$BRANCH" \
    --status "in_progress" \
    --json databaseId \
    --jq '.[0].databaseId' 2>/dev/null || true)

  if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
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

  echo "  Attempt $attempt/24: Workflow not found yet, waiting 5s..."
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

# Step 4: Wait, then change the secret
# For the multi-job test, we want to rotate AFTER the capture-secret job
# finishes but BEFORE print-from-artifact starts.
# For single-job tests, we rotate during the wait period.
CHANGE_DELAY=$((WAIT / 3))
if [ "$CHANGE_DELAY" -lt 10 ]; then
  CHANGE_DELAY=10
fi

echo "[4/7] Waiting ${CHANGE_DELAY}s before changing the secret..."
echo "  (Monitoring capture-secret job status...)"

# Poll for capture-secret job completion to optimize rotation timing
CAPTURE_JOB_DONE=false
for i in $(seq 1 "$CHANGE_DELAY"); do
  # Check if capture-secret job has completed
  CAPTURE_STATUS=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" \
    --jq '.jobs[] | select(.name == "capture-secret") | .status' 2>/dev/null || true)
  if [ "$CAPTURE_STATUS" = "completed" ] && [ "$CAPTURE_JOB_DONE" = "false" ]; then
    echo "  capture-secret job completed at t+${i}s — rotating NOW for multi-job test"
    CAPTURE_JOB_DONE=true
    # Don't break — let the delay continue for single-job tests
  fi
  if [ $((i % 10)) -eq 0 ]; then
    echo "  t+${i}s (capture-secret: ${CAPTURE_STATUS:-unknown})"
  fi
  sleep 1
done

echo ""
echo "  Changing secret NOW!"
gh secret set "$SECRET_NAME" -R "$REPO" --body "$CHANGED_SECRET"
echo "  Secret changed to: $CHANGED_SECRET"

# Rapid rotation mode: rotate many times in quick succession
if [ "$RAPID" = "1" ]; then
  echo ""
  echo "  Rapid rotation mode: performing 15 additional rotations..."
  for i in $(seq 1 15); do
    RAPID_SECRET="rapid-rotation-${i}-${TIMESTAMP}"
    gh secret set "$SECRET_NAME" -R "$REPO" --body "$RAPID_SECRET"
    echo "    Rotation $i/15: $RAPID_SECRET"
    sleep 2
  done
  # Set the final "changed" value
  gh secret set "$SECRET_NAME" -R "$REPO" --body "$CHANGED_SECRET"
  echo "  Final value: $CHANGED_SECRET"
fi
echo ""

# Step 5: Poll live logs while workflow is still running
echo "[5/7] Polling live logs for leaks during execution..."
LIVE_LOG_DIR=$(mktemp -d)
LIVE_LEAK_FOUND=false

for poll in $(seq 1 20); do
  # Check if run is still going
  RUN_STATUS=$(gh run view "$RUN_ID" -R "$REPO" --json status --jq '.status' 2>/dev/null || true)
  if [ "$RUN_STATUS" = "completed" ]; then
    echo "  Workflow completed during polling."
    break
  fi

  # Try to get logs for each job
  JOBS_JSON=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" 2>/dev/null || true)
  if [ -n "$JOBS_JSON" ]; then
    JOB_IDS=$(echo "$JOBS_JSON" | gh api --input - --jq '.jobs[].id' 2>/dev/null || \
              echo "$JOBS_JSON" | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[])]" 2>/dev/null || true)
    for JOB_ID in $JOB_IDS; do
      LIVE_LOG_FILE="${LIVE_LOG_DIR}/job-${JOB_ID}-poll-${poll}.log"
      gh api "repos/${REPO}/actions/jobs/${JOB_ID}/logs" > "$LIVE_LOG_FILE" 2>/dev/null || true
      if [ -s "$LIVE_LOG_FILE" ] && grep -q "$ORIGINAL_SECRET" "$LIVE_LOG_FILE" 2>/dev/null; then
        LIVE_LEAK_FOUND=true
        echo "  *** LIVE LEAK DETECTED in job $JOB_ID at poll $poll! ***"
      fi
    done
  fi

  echo "  Poll $poll/20 (status: ${RUN_STATUS:-unknown})"
  sleep 5
done
echo ""

# Step 6: Wait for workflow to complete and get final logs
echo "[6/7] Waiting for workflow to complete..."
gh run watch "$RUN_ID" -R "$REPO" --exit-status 2>/dev/null || true
echo "  Workflow completed."
echo ""

# Download final logs via multiple methods
echo "[7/7] Analyzing logs..."
echo ""

LOG_FILE=$(mktemp)
LOG_ZIP=$(mktemp --suffix=.zip)

# Method 1: gh run view --log
gh run view "$RUN_ID" -R "$REPO" --log > "$LOG_FILE" 2>/dev/null || true

# Method 2: API zip download
gh api "repos/${REPO}/actions/runs/${RUN_ID}/logs" > "$LOG_ZIP" 2>/dev/null || true
LOG_ZIP_DIR=$(mktemp -d)
unzip -q -o "$LOG_ZIP" -d "$LOG_ZIP_DIR" 2>/dev/null || true

echo "============================================"
echo "           TEST RESULTS"
echo "============================================"
echo ""

TOTAL_TESTS=0
LEAKS_FOUND=0

# Helper function
check_leak() {
  local TEST_NAME="$1"
  local PATTERN="$2"
  local LOG="$3"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  if grep -q "$PATTERN" "$LOG" 2>/dev/null; then
    LEAKS_FOUND=$((LEAKS_FOUND + 1))
    echo "  LEAKED  - $TEST_NAME"
    grep -n "$PATTERN" "$LOG" 2>/dev/null | head -3 | while read -r line; do
      echo "           $line"
    done
    return 0
  else
    echo "  MASKED  - $TEST_NAME"
    return 1
  fi
}

# --- Test 1: Single-job rotation ---
echo "[Test 1] Single-Job Rotation"
check_leak "Original secret after rotation" "$ORIGINAL_SECRET" "$LOG_FILE" || true
echo ""

# --- Test 2: Multi-job artifact handoff ---
echo "[Test 2] Multi-Job Artifact Handoff"
# Check specifically in the print-from-artifact job's output
if grep -q "print-from-artifact" "$LOG_FILE" 2>/dev/null; then
  ARTIFACT_LOG=$(mktemp)
  grep "print-from-artifact" "$LOG_FILE" > "$ARTIFACT_LOG" 2>/dev/null || true
  check_leak "V1 in artifact job (cross-job)" "$ORIGINAL_SECRET" "$ARTIFACT_LOG" || true
  rm -f "$ARTIFACT_LOG"
else
  echo "  SKIPPED - print-from-artifact job not found in logs"
fi
# Also check the zip logs for the artifact job
if ls "$LOG_ZIP_DIR"/*artifact* 2>/dev/null | head -1 > /dev/null 2>&1; then
  for f in "$LOG_ZIP_DIR"/*artifact*; do
    check_leak "V1 in artifact job (zip: $(basename "$f"))" "$ORIGINAL_SECRET" "$f" || true
  done
elif ls "$LOG_ZIP_DIR"/*print* 2>/dev/null | head -1 > /dev/null 2>&1; then
  for f in "$LOG_ZIP_DIR"/*print*; do
    check_leak "V1 in print job (zip: $(basename "$f"))" "$ORIGINAL_SECRET" "$f" || true
  done
fi
echo ""

# --- Test 3: Continuous output ---
echo "[Test 3] Continuous Output During Rotation"
if grep -q "test-continuous-output" "$LOG_FILE" 2>/dev/null; then
  CONTINUOUS_LOG=$(mktemp)
  grep "test-continuous-output" "$LOG_FILE" > "$CONTINUOUS_LOG" 2>/dev/null || true
  check_leak "V1 during continuous output" "$ORIGINAL_SECRET" "$CONTINUOUS_LOG" || true
  rm -f "$CONTINUOUS_LOG"
else
  echo "  SKIPPED - continuous output job not found"
fi
echo ""

# --- Test 4: Buffer flush ---
echo "[Test 4] Buffer Flush Before Print"
if grep -q "test-buffer-flush" "$LOG_FILE" 2>/dev/null; then
  BUFFER_LOG=$(mktemp)
  grep "test-buffer-flush" "$LOG_FILE" > "$BUFFER_LOG" 2>/dev/null || true
  check_leak "V1 after buffer flush" "$ORIGINAL_SECRET" "$BUFFER_LOG" || true
  rm -f "$BUFFER_LOG"
else
  echo "  SKIPPED - buffer flush job not found"
fi
echo ""

# --- Test 5: Late rotation ---
echo "[Test 5] Late Rotation During Print Phase"
if grep -q "test-late-rotation" "$LOG_FILE" 2>/dev/null; then
  LATE_LOG=$(mktemp)
  grep "test-late-rotation" "$LOG_FILE" > "$LATE_LOG" 2>/dev/null || true
  check_leak "V1 during late print phase" "$ORIGINAL_SECRET" "$LATE_LOG" || true
  rm -f "$LATE_LOG"
else
  echo "  SKIPPED - late rotation job not found"
fi
echo ""

# --- Test 6: GITHUB_OUTPUT passing ---
echo "[Test 6] GITHUB_OUTPUT Step Passing"
if grep -q "test-output-passing" "$LOG_FILE" 2>/dev/null; then
  OUTPUT_LOG=$(mktemp)
  grep "test-output-passing" "$LOG_FILE" > "$OUTPUT_LOG" 2>/dev/null || true
  check_leak "V1 via GITHUB_OUTPUT" "$ORIGINAL_SECRET" "$OUTPUT_LOG" || true
  rm -f "$OUTPUT_LOG"
else
  echo "  SKIPPED - output passing job not found"
fi
echo ""

# --- Test 7: Live log polling ---
echo "[Test 7] Live Log Polling (during execution)"
if [ "$LIVE_LEAK_FOUND" = "true" ]; then
  LEAKS_FOUND=$((LEAKS_FOUND + 1))
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  echo "  LEAKED  - V1 found in live-streamed logs during execution"
else
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  echo "  MASKED  - V1 not found in live logs"
fi
echo ""

# --- Test 8: Cross-method comparison ---
echo "[Test 8] Cross-Method Log Comparison"
ZIP_LEAK=false
for f in "$LOG_ZIP_DIR"/*; do
  [ -f "$f" ] || continue
  if grep -q "$ORIGINAL_SECRET" "$f" 2>/dev/null; then
    ZIP_LEAK=true
    echo "  LEAKED  - V1 found in zip log: $(basename "$f")"
    grep -n "$ORIGINAL_SECRET" "$f" 2>/dev/null | head -3 | while read -r line; do
      echo "           $line"
    done
  fi
done
if [ "$ZIP_LEAK" = "false" ]; then
  echo "  MASKED  - V1 not found in any zip log files"
fi
echo ""

# --- Summary ---
echo "============================================"
echo "                 SUMMARY"
echo "============================================"
echo ""
if [ "$LEAKS_FOUND" -gt 0 ]; then
  echo "  *** BUG REPRODUCED! ***"
  echo ""
  echo "  $LEAKS_FOUND leak(s) found across $TOTAL_TESTS tests."
  echo ""
  echo "  The original secret value appeared in clear text in the"
  echo "  workflow logs after being changed during the run."
else
  echo "  Bug NOT reproduced."
  echo ""
  echo "  0 leaks found across $TOTAL_TESTS tests."
  echo ""
  echo "  Suggestions:"
  echo "    - Increase wait time:   WAIT=120 ./reproduce.sh"
  echo "    - Try rapid rotations:  RAPID=1 ./reproduce.sh"
  echo "    - Run multiple times to catch timing-dependent races"
  echo "    - Try longer windows:   WAIT=300 ./reproduce.sh"
fi
echo ""
echo "============================================"
echo ""
echo "Full logs:    $LOG_FILE"
echo "Zip logs:     $LOG_ZIP_DIR"
echo "Live logs:    $LIVE_LOG_DIR"
echo "Run URL:      https://github.com/$REPO/actions/runs/$RUN_ID"

# Cleanup: reset the secret to a harmless value
echo ""
echo "Cleaning up: resetting secret to a dummy value..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "placeholder-rotate-me"
echo "Done."

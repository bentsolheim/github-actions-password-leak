#!/usr/bin/env bash
#
# reproduce.sh - Test GitHub Actions secret masking coverage
#
# Tests which encodings/transformations of a secret value bypass masking.
# GitHub masks the literal string and base64, but may miss other formats.
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
SECRET_VALUE="original-secret-value-${TIMESTAMP}"
CHANGED_SECRET="changed-secret-value-${TIMESTAMP}"

echo "============================================"
echo " Secret Masking Transform Test"
echo "============================================"
echo ""
echo "Repository:  $REPO"
echo "Branch:      $BRANCH"
echo "Secret:      $SECRET_VALUE"
echo "Wait time:   ${WAIT}s"
echo ""

# Pre-compute expected outputs for each transformation
declare -A EXPECTED
EXPECTED[LITERAL]="$SECRET_VALUE"
EXPECTED[HEX_XXD]=$(printf '%s' "$SECRET_VALUE" | xxd -p | tr -d '\n')
EXPECTED[HEX_OD]=$(printf '%s' "$SECRET_VALUE" | od -A n -t x1 | tr -d ' \n')
EXPECTED[OCTAL]=$(printf '%s' "$SECRET_VALUE" | od -A n -t o1 | tr -d ' \n')
EXPECTED[B64_NO_NL]=$(printf '%s' "$SECRET_VALUE" | base64)
EXPECTED[B64_WITH_NL]=$(echo "$SECRET_VALUE" | base64)
EXPECTED[BASE32]=$(printf '%s' "$SECRET_VALUE" | base32)
EXPECTED[REVERSED]=$(echo "$SECRET_VALUE" | rev)
EXPECTED[ROT13]=$(echo "$SECRET_VALUE" | tr 'a-zA-Z' 'n-za-mN-ZA-M')
EXPECTED[UPPER]=$(echo "$SECRET_VALUE" | tr '[:lower:]' '[:upper:]')
EXPECTED[CAESAR1]=$(echo "$SECRET_VALUE" | tr 'a-zA-Z0-9' 'b-za-aB-ZA-A1-90')
EXPECTED[MD5]=$(printf '%s' "$SECRET_VALUE" | md5sum | cut -d' ' -f1)
EXPECTED[SHA1]=$(printf '%s' "$SECRET_VALUE" | sha1sum | cut -d' ' -f1)
EXPECTED[SHA256]=$(printf '%s' "$SECRET_VALUE" | sha256sum | cut -d' ' -f1)
EXPECTED[FIRST_HALF]="${SECRET_VALUE:0:$(( ${#SECRET_VALUE} / 2 ))}"
EXPECTED[SECOND_HALF]="${SECRET_VALUE:$(( ${#SECRET_VALUE} / 2 ))}"

# Decimal ASCII
DEC_ASCII=""
for (( i=0; i<${#SECRET_VALUE}; i++ )); do
  DEC_ASCII+="$(printf '%d ' "'${SECRET_VALUE:$i:1}")"
done
EXPECTED[DECIMAL_ASCII]="$DEC_ASCII"

# HTML entities
HTML_ENT=$(python3 -c "
s = '$SECRET_VALUE'
print(''.join(f'&#{ord(c)};' for c in s))
")
EXPECTED[HTML_ENTITIES]="$HTML_ENT"

# Unicode escapes
UNICODE_ESC=$(python3 -c "
s = '$SECRET_VALUE'
print(''.join(f'\\\\u{ord(c):04x}' for c in s))
")
EXPECTED[UNICODE_ESC]="$UNICODE_ESC"

# URL encoding (only encodes special chars, letters/digits pass through)
EXPECTED[URL_ENCODE]=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$SECRET_VALUE'))")
EXPECTED[URL_ENCODE_ALL]=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$SECRET_VALUE', safe=''))")

# Hex via printf
HEX_PRINTF=""
for (( i=0; i<${#SECRET_VALUE}; i++ )); do
  HEX_PRINTF+=$(printf '%02x' "'${SECRET_VALUE:$i:1}")
done
EXPECTED[HEX_PRINTF]="$HEX_PRINTF"

# Spaced chars
EXPECTED[SPACED]=$(echo "$SECRET_VALUE" | sed 's/./& /g')

# Even/odd chars
EVEN=""
ODD=""
for (( i=0; i<${#SECRET_VALUE}; i++ )); do
  if (( i % 2 == 0 )); then
    EVEN+="${SECRET_VALUE:$i:1}"
  else
    ODD+="${SECRET_VALUE:$i:1}"
  fi
done
EXPECTED[EVEN_CHARS]="$EVEN"
EXPECTED[ODD_CHARS]="$ODD"

# Binary
EXPECTED[BINARY]=$(python3 -c "
s = '$SECRET_VALUE'
print(' '.join(f'{ord(c):08b}' for c in s))
")

# Artifact variants
EXPECTED[ARTIFACT_LITERAL]="$SECRET_VALUE"
EXPECTED[ARTIFACT_HEX]=$(printf '%s' "$SECRET_VALUE" | xxd -p | tr -d '\n')
EXPECTED[ARTIFACT_B64]=$(printf '%s' "$SECRET_VALUE" | base64)
EXPECTED[ARTIFACT_B64NL]=$(echo "$SECRET_VALUE" | base64)

echo "Pre-computed ${#EXPECTED[@]} transformation patterns."
echo ""

# Step 1: Set the secret
echo "[1/5] Setting secret..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "$SECRET_VALUE"
sleep 2
echo ""

# Step 2: Trigger workflow
echo "[2/5] Triggering workflow..."
gh workflow run secret-leak-test.yml \
  -R "$REPO" \
  --ref "$BRANCH" \
  -f "wait_seconds=$WAIT"
echo "  Waiting 5s for registration..."
sleep 5
echo ""

# Step 3: Find the run
echo "[3/5] Finding workflow run..."
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
  echo "  Attempt $attempt/24: waiting 5s..."
  sleep 5
done

if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
  echo "ERROR: Could not find the workflow run."
  exit 1
fi

echo "  Run: $RUN_ID"
echo "  URL: https://github.com/$REPO/actions/runs/$RUN_ID"
echo ""

# Step 4: Rotate secret mid-run (for rotation tests)
CHANGE_DELAY=$((WAIT / 3))
[ "$CHANGE_DELAY" -lt 10 ] && CHANGE_DELAY=10
echo "[4/5] Waiting ${CHANGE_DELAY}s then rotating secret..."
sleep "$CHANGE_DELAY"
gh secret set "$SECRET_NAME" -R "$REPO" --body "$CHANGED_SECRET"
echo "  Rotated to: $CHANGED_SECRET"
echo ""

# Wait for completion
echo "  Waiting for workflow to complete..."
gh run watch "$RUN_ID" -R "$REPO" --exit-status 2>/dev/null || true
echo "  Done."
echo ""

# Step 5: Analyze logs
echo "[5/5] Analyzing logs..."
LOG_FILE=$(mktemp)
gh run view "$RUN_ID" -R "$REPO" --log > "$LOG_FILE" 2>/dev/null || true

# Split logs by job for accurate per-job analysis
TRANSFORM_LOG=$(mktemp)
ARTIFACT_LOG=$(mktemp)
grep "^test-masking-transforms" "$LOG_FILE" > "$TRANSFORM_LOG" 2>/dev/null || true
grep "^print-from-artifact" "$LOG_FILE" > "$ARTIFACT_LOG" 2>/dev/null || true

echo ""
echo "============================================================"
echo "  MASKING TRANSFORM RESULTS"
echo "============================================================"
echo ""

# Categorize results
LEAKED_LIST=()
MASKED_LIST=()

# Define display order and groupings
declare -a GROUPS_ORDER=(
  "CONTROLS"
  "HEX_ENCODINGS"
  "NUMERIC_ENCODINGS"
  "BASE_ENCODINGS"
  "URL_HTML_UNICODE"
  "STRING_TRANSFORMS"
  "PARTIAL_EXPOSURE"
  "STRUCTURED_DATA"
  "HASHES"
  "ARTIFACT_CROSS_JOB"
)

declare -A GROUP_NAMES
GROUP_NAMES[CONTROLS]="Controls (should be masked)"
GROUP_NAMES[HEX_ENCODINGS]="Hex Encodings"
GROUP_NAMES[NUMERIC_ENCODINGS]="Numeric Encodings"
GROUP_NAMES[BASE_ENCODINGS]="Base Encodings"
GROUP_NAMES[URL_HTML_UNICODE]="URL / HTML / Unicode"
GROUP_NAMES[STRING_TRANSFORMS]="String Transforms"
GROUP_NAMES[PARTIAL_EXPOSURE]="Partial Exposure"
GROUP_NAMES[STRUCTURED_DATA]="Structured Data Embedding"
GROUP_NAMES[HASHES]="Hashes (non-reversible)"
GROUP_NAMES[ARTIFACT_CROSS_JOB]="Artifact Cross-Job"

declare -A GROUP_KEYS
GROUP_KEYS[CONTROLS]="LITERAL B64_NO_NL"
GROUP_KEYS[HEX_ENCODINGS]="HEX_XXD HEX_OD HEX_PRINTF"
GROUP_KEYS[NUMERIC_ENCODINGS]="OCTAL DECIMAL_ASCII BINARY"
GROUP_KEYS[BASE_ENCODINGS]="B64_WITH_NL BASE32"
GROUP_KEYS[URL_HTML_UNICODE]="URL_ENCODE URL_ENCODE_ALL HTML_ENTITIES UNICODE_ESC"
GROUP_KEYS[STRING_TRANSFORMS]="REVERSED SPACED ROT13 UPPER CAESAR1"
GROUP_KEYS[PARTIAL_EXPOSURE]="FIRST_HALF SECOND_HALF EVEN_CHARS ODD_CHARS"
GROUP_KEYS[STRUCTURED_DATA]=""
GROUP_KEYS[HASHES]="MD5 SHA1 SHA256"
GROUP_KEYS[ARTIFACT_CROSS_JOB]="ARTIFACT_LITERAL ARTIFACT_HEX ARTIFACT_B64 ARTIFACT_B64NL"

check_transform() {
  local KEY="$1"
  local EXPECTED_VAL="${EXPECTED[$KEY]:-}"
  local SEARCH_FILE="${2:-$TRANSFORM_LOG}"

  if [ -z "$EXPECTED_VAL" ]; then
    printf "  %-20s  SKIP  (no expected value)\n" "$KEY"
    return
  fi

  # Use fixed-string grep on the per-job log (not the whole file)
  if grep -qF "$EXPECTED_VAL" "$SEARCH_FILE" 2>/dev/null; then
    printf "  %-20s  \e[31mLEAKED\e[0m\n" "$KEY"
    LEAKED_LIST+=("$KEY")
  else
    printf "  %-20s  \e[32mMASKED\e[0m\n" "$KEY"
    MASKED_LIST+=("$KEY")
  fi
}

for GROUP in "${GROUPS_ORDER[@]}"; do
  echo "--- ${GROUP_NAMES[$GROUP]} ---"
  if [ "$GROUP" = "ARTIFACT_CROSS_JOB" ]; then
    # Artifact tests use the artifact job's log, not the transform job
    for KEY in ${GROUP_KEYS[$GROUP]}; do
      check_transform "$KEY" "$ARTIFACT_LOG"
    done
  else
    for KEY in ${GROUP_KEYS[$GROUP]}; do
      check_transform "$KEY"
    done
  fi
  echo ""
done

# Structured data patterns (search transform job log only)
echo "--- Structured Data Embedding ---"
for PATTERN in "token=${SECRET_VALUE}" "admin:${SECRET_VALUE}@" ; do
  if grep -qF "$PATTERN" "$TRANSFORM_LOG" 2>/dev/null; then
    printf "  %-20s  \e[31mLEAKED\e[0m\n" "PATTERN: $PATTERN"
    LEAKED_LIST+=("STRUCT:$PATTERN")
  else
    printf "  %-20s  \e[32mMASKED\e[0m\n" "PATTERN: $PATTERN"
  fi
done
echo ""

# Summary
echo "============================================================"
echo "  SUMMARY"
echo "============================================================"
echo ""
echo "  Total transforms tested: $(( ${#LEAKED_LIST[@]} + ${#MASKED_LIST[@]} ))"
echo "  Leaked:  ${#LEAKED_LIST[@]}"
echo "  Masked:  ${#MASKED_LIST[@]}"
echo ""

if [ ${#LEAKED_LIST[@]} -gt 0 ]; then
  echo "  LEAKED transforms:"
  for KEY in "${LEAKED_LIST[@]}"; do
    VAL="${EXPECTED[$KEY]:-structured pattern}"
    # Truncate long values
    if [ ${#VAL} -gt 60 ]; then
      VAL="${VAL:0:57}..."
    fi
    echo "    $KEY = $VAL"
  done
  echo ""
  echo "  These encodings BYPASS GitHub Actions secret masking."
  echo "  Any workflow that outputs a secret in these formats will"
  echo "  expose the value in cleartext in the logs."
else
  echo "  All transforms were properly masked."
fi

echo ""
echo "============================================================"
echo ""
echo "Log file:  $LOG_FILE"
echo "Run URL:   https://github.com/$REPO/actions/runs/$RUN_ID"

# Cleanup
echo ""
echo "Cleaning up..."
gh secret set "$SECRET_NAME" -R "$REPO" --body "placeholder-rotate-me"
echo "Done."

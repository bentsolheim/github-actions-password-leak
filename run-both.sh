#!/usr/bin/env bash
#
# run-both.sh — Run the A/B experiment (vulnerable then mitigated)
#
# Executes both workflows sequentially and prints a comparative summary.
# Environment variables (REPO, BRANCH, WAIT) are forwarded to each script.
#
# Usage:
#   ./run-both.sh
#   WAIT=60 ./run-both.sh

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "############################################"
echo "#                                          #"
echo "#   GitHub Actions Secret Masking Bug      #"
echo "#   A/B Experiment                         #"
echo "#                                          #"
echo "############################################"
echo ""
echo "This script runs two workflows back-to-back:"
echo "  1. Vulnerable — no direct secret ref in print job (expects LEAK)"
echo "  2. Mitigated  — direct secret ref in both jobs    (expects MASK)"
echo ""

echo "============================================"
echo " Part 1 of 2: Vulnerable Workflow"
echo "============================================"
echo ""
"$DIR/run-vulnerable.sh"

echo ""
echo ""

echo "============================================"
echo " Part 2 of 2: Mitigated Workflow"
echo "============================================"
echo ""
"$DIR/run-mitigated.sh"

echo ""
echo ""
echo "############################################"
echo "#  A/B Experiment — Summary                #"
echo "############################################"
echo ""
echo "  Vulnerable workflow:  V1 should have LEAKED (old secret in cleartext)"
echo "  Mitigated workflow:   V1 should have been MASKED (secret stayed hidden)"
echo ""
echo "  The only difference between the two workflows is that the mitigated"
echo "  version adds a direct \${{ secrets.TEST_SECRET }} reference in both"
echo "  jobs. This forces GitHub Actions to include all known secret values"
echo "  in each job's masking dictionary — even the pre-rotation value."
echo ""
echo "  Review the RESULTS sections above for each workflow's masking matrix."
echo ""

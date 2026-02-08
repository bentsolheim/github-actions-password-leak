# GitHub Actions Secret Masking Bug — A/B Experiment

## Project Overview

This repository demonstrates a bug in GitHub Actions where rotating a repository
secret while a workflow is running causes the old secret value to appear unmasked
in workflow logs via cross-job output forwarding. An A/B experiment compares a
vulnerable workflow (leaks) against a mitigated workflow (masks).

## Key Files

- `.github/workflows/vulnerable.yml` - Vulnerable workflow: only the capture job
  references `${{ secrets.TEST_SECRET }}`, so the print job leaks V1 after rotation
- `.github/workflows/mitigated.yml` - Mitigated workflow: both jobs reference
  `${{ secrets.TEST_SECRET }}`, so V1 stays in the masking dictionary
- `run-vulnerable.sh` - Triggers the vulnerable workflow, rotates the secret
  mid-run, and checks logs for the leak
- `run-mitigated.sh` - Triggers the mitigated workflow, rotates the secret
  mid-run, and verifies V1 is masked
- `run-both.sh` - Runs both scripts sequentially and prints a comparative summary

## Development

- Both workflows use `workflow_dispatch` with a configurable `wait_seconds` input
- The `TEST_SECRET` repository secret is the target for rotation testing
- All three scripts require `gh` CLI authenticated with repo and secrets access
- Environment overrides: `REPO`, `BRANCH`, `WAIT`

## Conventions

- Shell scripts should use `set -euo pipefail`
- Workflow steps should have descriptive `name:` fields
- Keep the reproduction minimal and self-contained

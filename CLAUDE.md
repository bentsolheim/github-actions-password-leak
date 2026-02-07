# GitHub Actions Secret Masking Bug Reproduction

## Project Overview

This repository attempts to reproduce a bug in GitHub Actions where rotating a
repository secret while a workflow is running causes the old secret value to
appear unmasked in workflow logs.

## Key Files

- `.github/workflows/secret-leak-test.yml` - Workflow that captures a secret,
  waits, then prints it in various formats to test masking
- `reproduce.sh` - Automated script that triggers the workflow and rotates
  the secret mid-run, then checks logs for leaks

## Development

- Branch: `claude/reproduce-secrets-bug-ysKN2`
- The workflow uses `workflow_dispatch` with a configurable `wait_seconds` input
- The `TEST_SECRET` repository secret is the target for rotation testing
- `reproduce.sh` requires `gh` CLI authenticated with repo and secrets access

## Conventions

- Shell scripts should use `set -euo pipefail`
- Workflow steps should have descriptive `name:` fields
- Keep the reproduction minimal and self-contained

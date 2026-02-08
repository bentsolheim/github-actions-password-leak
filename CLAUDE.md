# GitHub Actions Secret Masking Bug Reproduction

## Project Overview

This repository reproduces a bug in GitHub Actions where rotating a repository
secret while a workflow is running causes the old secret value to appear
unmasked in workflow logs via cross-job output forwarding.

## Key Files

- `.github/workflows/cross-job-secret-leak.yml` - Two-job workflow: capture
  encodes the secret as a job output, print decodes and prints it after rotation
- `reproduce.sh` - Automated script that triggers the workflow, rotates the
  secret between jobs, and checks logs for leaks

## Development

- The workflow uses `workflow_dispatch` with a configurable `wait_seconds` input
- The `TEST_SECRET` repository secret is the target for rotation testing
- `reproduce.sh` requires `gh` CLI authenticated with repo and secrets access

## Conventions

- Shell scripts should use `set -euo pipefail`
- Workflow steps should have descriptive `name:` fields
- Keep the reproduction minimal and self-contained

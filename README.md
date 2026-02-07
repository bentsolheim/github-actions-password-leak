# github-actions-password-leak

Reproduction case for a potential GitHub Actions bug where changing a repository
secret while a workflow is running causes the **old** secret value to appear
unmasked (in clear text) in the workflow logs.

## Theory

GitHub Actions masks secret values in workflow logs by pattern-matching known
secret values against output text. When a secret is rotated (changed) while a
workflow is actively running:

1. The workflow received the **old** secret value at job start time
2. The secret is updated in the repository settings
3. GitHub's log masking may only know about the **new** secret value
4. The **old** value, still being used by the running workflow, is no longer
   recognized as a secret and gets printed in clear text

## Files

- `.github/workflows/secret-leak-test.yml` - The workflow that captures and
  prints a secret with a configurable delay between capture and output
- `reproduce.sh` - Automated script that sets a secret, triggers the workflow,
  changes the secret mid-run, then checks the logs for leaks

## Quick Start

### Prerequisites

- `gh` CLI installed and authenticated (`gh auth login`)
- Push access to this repository
- Permission to manage repository secrets

### Automated Reproduction

```bash
# Clone and run
git clone https://github.com/bentsolheim/github-actions-password-leak.git
cd github-actions-password-leak

# Run with defaults (30s wait window)
./reproduce.sh

# Run with longer wait window
WAIT=120 ./reproduce.sh
```

### Manual Reproduction

1. Create a repository secret called `TEST_SECRET` with any value
2. Trigger the workflow (Actions tab > "Secret Leak Reproduction Test" > Run workflow)
3. While the workflow is in the "Wait" step, change `TEST_SECRET` to a different value
4. After the workflow completes, check the logs for the original secret value in plain text

## What to Look For

- **Bug reproduced**: The original secret value appears in clear text in the logs
  (not replaced with `***`)
- **Bug not reproduced**: All secret values show as `***` in the logs
# GitHub Actions Secret Masking Bug

When a GitHub Actions repository secret is rotated while a workflow is running,
the old secret value can appear **unmasked in cleartext** in the workflow logs.

## The Bug

Each GitHub Actions job receives its own masking dictionary — the set of values
the runner will replace with `***` in logs. When a secret is rotated mid-workflow:

1. **Job A** starts, reads the secret (old value V1), and passes it to Job B
   via a job output.
2. The secret is rotated externally (V1 -> V2).
3. **Job B** starts. Its masking dictionary contains only V2 (the new value).
4. Job B decodes V1 from the job output and prints it. Because V1 is not in
   Job B's masking dictionary, **it appears in cleartext in the logs**.

The job output uses double-base64 encoding to bypass GitHub's check that blocks
setting outputs containing known secret substrings.

### Expected Masking Matrix

| Job     | V1 (old secret) | V2 (new secret) |
|---------|-----------------|-----------------|
| capture | MASKED          | MASKED          |
| print   | **LEAKED**      | MASKED          |

- **capture**: V1 is the active secret, so it's masked. V2 doesn't appear in
  this job's output, so it trivially cannot leak.
- **print**: V2 is the active secret (masked). V1 arrives via the job output
  and is NOT in this job's masking dictionary, so it leaks.

## How the Reproduction Works

The workflow (`.github/workflows/cross-job-secret-leak.yml`) has two jobs:

- **capture** — reads `TEST_SECRET`, double-base64-encodes it, and sets it as a
  job output. Then waits for a configurable duration (the rotation window).
- **print** — receives the encoded output, decodes it, and prints the value.

The script `reproduce.sh` orchestrates the full cycle:

1. Sets `TEST_SECRET` to V1
2. Triggers the workflow
3. Waits for the capture job to finish
4. Rotates `TEST_SECRET` to V2
5. Waits for the print job to finish
6. Checks the print job's logs for V1 in cleartext

## Usage

### Prerequisites

- [`gh` CLI](https://cli.github.com/) installed and authenticated (`gh auth login`)
- Push access to this repository
- Permission to manage repository secrets

### Run

```bash
./reproduce.sh
```

Override defaults with environment variables:

```bash
REPO=your-org/your-repo WAIT=60 ./reproduce.sh
```

### What to Look For

The script prints a masking matrix showing whether each secret value was masked
or leaked in each job:

```
  Job          V1 (old secret)    V2 (new secret)
  ----------   ----------------   ----------------
  capture      MASKED             MASKED
  print        LEAKED             MASKED
```

- **`Bug reproduced`** — V1 leaked in the print job while everything else was
  correctly masked. This is the expected result demonstrating the bug.
- **`V1 was masked. Leak not reproduced.`** — the masking worked correctly
  across jobs, meaning the bug was not triggered.

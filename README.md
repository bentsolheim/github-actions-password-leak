# GitHub Actions Secret Masking Bug — A/B Experiment

An A/B experiment demonstrating that rotating a GitHub Actions secret mid-workflow
causes the old value to leak in cleartext — and how a one-line mitigation prevents it.

## Background

Each job in a GitHub Actions workflow gets its own **masking dictionary** — the set
of values the runner replaces with `***` in logs. The dictionary is populated when
the job starts, using the secret values known *at that moment*.

When a secret is rotated while a workflow is running:

1. **Job A** starts with the old value (V1) in its masking dictionary.
2. Job A encodes V1 as a job output (double-base64 to bypass output guards).
3. The secret is rotated externally (V1 → V2).
4. **Job B** starts. Its masking dictionary contains only V2.
5. Job B decodes V1 from the job output and prints it — **V1 appears in cleartext**.

## The A/B Experiment

This repo contains two nearly identical workflows. The only difference is whether
the `print` job directly references `${{ secrets.TEST_SECRET }}`:

| | Vulnerable (`vulnerable.yml`) | Mitigated (`mitigated.yml`) |
|---|---|---|
| `capture` job references secret | Yes | Yes |
| `print` job references secret | **No** | **Yes** |
| V1 after rotation | **LEAKED** | MASKED |

Both workflows are triggered with the same rotation timing so the only variable
is the workflow content itself.

## Why the Mitigation Works

When a job's YAML contains a direct `${{ secrets.TEST_SECRET }}` expression,
GitHub resolves the secret and adds **all known values** for that secret to the
job's masking dictionary — including the pre-rotation value V1. This means V1
is masked even though the job received V2 as the "current" value.

By adding a trivial step that references the secret in the `print` job, V1
enters the masking dictionary and the leak is prevented.

## Workflows

### `vulnerable.yml` — Vulnerable: Cross-Job Secret Leak

Two jobs (`capture` → `print`). Only the `capture` job references
`${{ secrets.TEST_SECRET }}`. The `print` job receives V1 via job outputs
but has no secret reference of its own, so V1 is not in its masking dictionary.

### `mitigated.yml` — Mitigated: Cross-Job Secret Leak

Same structure, but **both** jobs contain a step that references
`${{ secrets.TEST_SECRET }}`. This populates V1 into the `print` job's
masking dictionary, preventing the leak.

## Usage

### Prerequisites

- [`gh` CLI](https://cli.github.com/) installed and authenticated (`gh auth login`)
- Push access to this repository
- Permission to manage repository secrets

### Run both (recommended)

```bash
./run-both.sh
```

This runs the vulnerable workflow first, then the mitigated workflow, and prints
a comparative summary.

### Run individually

```bash
./run-vulnerable.sh    # expects V1 to LEAK
./run-mitigated.sh     # expects V1 to be MASKED
```

### Environment overrides

```bash
REPO=your-org/your-repo BRANCH=main WAIT=60 ./run-both.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `REPO` | `bentsolheim/github-actions-password-leak` | Target repository |
| `BRANCH` | `main` | Branch to trigger workflows on |
| `WAIT` | `30` | Seconds the capture job sleeps (rotation window) |

## Expected Output

### Vulnerable workflow (`run-vulnerable.sh`)

```
  V1 in print job:  LEAKED
  V2 in print job:  NOT FOUND

  RESULT: V1 LEAKED in cross-job output.
```

### Mitigated workflow (`run-mitigated.sh`)

```
  Job          V1 (old secret)    V2 (new secret)
  ----------   ----------------   ----------------
  capture      MASKED             MASKED
  print        MASKED             MASKED

  RESULT: V1 was masked. Leak not reproduced.
```

## Repository Structure

```
.github/workflows/
  vulnerable.yml        Workflow with no secret ref in print job (leaks V1)
  mitigated.yml         Workflow with secret ref in both jobs (masks V1)
run-vulnerable.sh       Triggers vulnerable.yml, rotates secret, checks for leak
run-mitigated.sh        Triggers mitigated.yml, rotates secret, checks for masking
run-both.sh             Runs both scripts and prints a comparative summary
README.md               This file
CLAUDE.md               Project conventions for AI-assisted development
```

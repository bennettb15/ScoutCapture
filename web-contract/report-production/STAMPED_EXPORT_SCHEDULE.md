# Stamped Export Scheduled Worker

## Recommended Runtime

Use GitHub Actions as the first scheduled cloud worker for stamped photo exports.

Why this is the smallest safe option:

- It can run the existing Docker worker image without changing the Python
  runtime contract.
- It supports scheduled runs every 5 minutes, which is the minimum GitHub cron
  interval.
- Secrets are stored in GitHub Actions secrets, not in the repository or
  browser code.
- It is cheap and low-ops for the current validation volume.
- It is easy to disable by changing one repository variable or disabling the
  workflow.

This keeps Vercel as the website/API control plane only. Vercel does not
generate stamped images.

## Workflow

Repo-side workflow:

```text
.github/workflows/stamped-export-worker.yml
```

Schedule:

```text
*/5 * * * *
```

The schedule is intentionally guarded. Scheduled runs only process jobs when the
repository variable below is set:

```text
STAMPED_EXPORT_WORKER_ENABLED=true
```

Manual `workflow_dispatch` runs are allowed even while the schedule is disabled.

## Required GitHub Secrets

Set these as GitHub Actions repository secrets:

```text
SCOUT_DEV_SUPABASE_URL=https://chlvazmtucoszicehtnm.supabase.co
SCOUT_DEV_SUPABASE_SERVICE_ROLE_KEY=[scout-dev service-role key]
```

Do not use a `VITE_` prefix. Do not print or commit the service-role key.

## Current Validation Allowlist

The workflow is intentionally restricted to the scout-dev validation
org/property:

```text
d4ba94ff-25e1-4072-aa79-9a548fcb3008:d626703e-671b-44e1-a26d-642c5597730e
```

Do not remove this allowlist or create a global worker until explicitly
approved.

## Scheduled Command

The workflow builds the Docker image, runs the production runtime preflight, and
then runs:

```bash
docker run --rm \
  -e SUPABASE_URL \
  -e SUPABASE_SERVICE_ROLE_KEY \
  scoutcapture-report-worker:stamped-export \
    --stamped-zip-poll-once \
    --allow-remote-validation \
    --expected-project-ref chlvazmtucoszicehtnm \
    --allow-org-property d4ba94ff-25e1-4072-aa79-9a548fcb3008:d626703e-671b-44e1-a26d-642c5597730e \
    --stamped-zip-limit 5 \
    --pretty
```

## Enable

1. Add the two GitHub Actions secrets.
2. Set repository variable:

```text
STAMPED_EXPORT_WORKER_ENABLED=true
```

3. Run the workflow manually once from GitHub Actions.
4. Confirm queued exports are processed.
5. Leave the variable enabled for the 5-minute schedule.

## Disable

Preferred:

```text
STAMPED_EXPORT_WORKER_ENABLED=false
```

Or remove the variable entirely. The schedule may still trigger, but the job will
not run.

You can also disable the workflow in the GitHub Actions UI.

## Manual One-Time Run

Use GitHub Actions `workflow_dispatch` on `main`. Manual dispatch does not
require `STAMPED_EXPORT_WORKER_ENABLED=true`, but it still requires the secrets
and the hardcoded scout-dev org/property allowlist.

Local equivalent:

```bash
docker build -f web-contract/report-production/Dockerfile -t scoutcapture-report-worker:stamped-export .
docker run --rm scoutcapture-report-worker:stamped-export --runtime-check --pretty --require-heif
docker run --rm \
  -e SUPABASE_URL=https://chlvazmtucoszicehtnm.supabase.co \
  -e SUPABASE_SERVICE_ROLE_KEY=[redacted] \
  scoutcapture-report-worker:stamped-export \
    --stamped-zip-poll-once \
    --allow-remote-validation \
    --expected-project-ref chlvazmtucoszicehtnm \
    --allow-org-property d4ba94ff-25e1-4072-aa79-9a548fcb3008:d626703e-671b-44e1-a26d-642c5597730e \
    --stamped-zip-limit 5 \
    --pretty
```

## Verify

The worker output should show:

- `mode`: `stamped-zip-poll-once`
- `processed`: queued exports claimed and marked `ready`
- `skipped`: only non-allowlisted or already-claimed jobs
- `production_writes_made`: `false`
- `remote_validation_writes_made`: `true` for scout-dev

For a processed export, verify:

- `temporary_exports.status = ready`
- `storage_bucket = scoutcapture-deliverables`
- `storage_path` matches the expected stamped ZIP path
- ZIP filename is customer-friendly
- ZIP magic bytes are `50 4b 03 04`
- stamped JPG entries have magic bytes `ff d8 ff`

## Production Note

This workflow is still scoped to scout-dev. Before moving beyond validation,
create an explicit production target decision, set production-specific secrets,
and approve the production org/property/session allowlist or a replacement
authorization strategy. Do not enable global processing by default.

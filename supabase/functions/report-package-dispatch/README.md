# Report Package Dispatch Edge Function

This function is a narrow QA Test 9.5 bridge from a completed sealed
`session_snapshots` insert to the existing GitHub Actions Report Package Worker.

The iOS app never receives GitHub credentials. The function validates the
database webhook payload, rejects anything outside Test Org / QA Test 9.5, and
dispatches `.github/workflows/report-package-worker.yml` with `session_id` and
`snapshot_id` inputs. The workflow still runs the existing idempotent
`--poll-once` worker path, restricted to the triggering session, so duplicate
snapshots are deduped to the latest completed sealed snapshot and ready packages
are skipped.

## Required Secrets

Set these as Supabase Edge Function secrets:

```bash
supabase secrets set REPORT_PACKAGE_DISPATCH_SECRET='<shared random value>'
supabase secrets set GITHUB_REPORT_WORKER_TOKEN='<fine-grained GitHub token with Actions write access to bennettb15/ScoutCapture>'
```

Optional overrides, if needed:

```bash
supabase secrets set GITHUB_REPOSITORY='bennettb15/ScoutCapture'
supabase secrets set GITHUB_REPORT_WORKER_WORKFLOW='report-package-worker.yml'
supabase secrets set GITHUB_REPORT_WORKER_REF='main'
supabase secrets set REPORT_PACKAGE_TRIGGER_ALLOWED_ORG_ID='d4ba94ff-25e1-4072-aa79-9a548fcb3008'
supabase secrets set REPORT_PACKAGE_TRIGGER_ALLOWED_PROPERTY_ID='d626703e-671b-44e1-a26d-642c5597730e'
```

Deploy with JWT verification disabled only because the database trigger/webhook
uses the shared secret header instead of a user JWT:

```bash
supabase functions deploy report-package-dispatch --no-verify-jwt
```

Then install either the Supabase Dashboard Database Webhook or the SQL snippet
at `supabase/snippets/report_package_snapshot_webhook.sql`.

-- Optional production-validation trigger for QA Test 9.5 only.
-- Prefer creating this from the Supabase Dashboard Database Webhooks UI. This
-- SQL form matches Supabase's documented `supabase_functions.http_request`
-- webhook helper, which uses pg_net asynchronously.
--
-- Apply only after deploying the `report-package-dispatch` Edge Function and
-- setting REPORT_PACKAGE_DISPATCH_SECRET plus GITHUB_REPORT_WORKER_TOKEN as
-- Supabase Edge Function secrets.
--
-- Replace both placeholders before running:
--   __PROJECT_REF__ with the Supabase project ref, for example chlvazmtucoszicehtnm
--   __REPORT_PACKAGE_DISPATCH_SECRET__ with the shared dispatch secret value.
-- The secret value is sent as an HTTP header; do not commit the substituted SQL.

drop trigger if exists scoutcapture_dispatch_qa95_report_package_on_snapshot on public.session_snapshots;

create trigger scoutcapture_dispatch_qa95_report_package_on_snapshot
after insert on public.session_snapshots
for each row
when (
  new.snapshot_kind = 'completed'
  and new.session_status = 'completed'
  and coalesce(new.is_sealed, false) is true
  and new.deleted_at is null
  and lower(new.org_id::text) = 'd4ba94ff-25e1-4072-aa79-9a548fcb3008'
  and lower(new.property_id::text) = 'd626703e-671b-44e1-a26d-642c5597730e'
)
execute function supabase_functions.http_request(
  'https://__PROJECT_REF__.functions.supabase.co/report-package-dispatch',
  'POST',
  '{"Content-Type":"application/json","x-scoutcapture-report-trigger-secret":"__REPORT_PACKAGE_DISPATCH_SECRET__"}',
  '{}',
  '5000'
);

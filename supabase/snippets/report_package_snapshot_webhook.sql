-- Optional report package dispatch trigger for completed sealed snapshots.
-- Prefer creating this from the Supabase Dashboard Database Webhooks UI. This
-- SQL form matches Supabase's documented `supabase_functions.http_request`
-- webhook helper, which uses pg_net asynchronously.
--
-- Apply only after deploying the `report-package-dispatch` Edge Function and
-- setting REPORT_PACKAGE_DISPATCH_SECRET plus GITHUB_REPORT_WORKER_TOKEN as
-- Supabase Edge Function secrets.
--
-- Replace the shared dispatch secret placeholder before running:
--   __REPORT_PACKAGE_DISPATCH_SECRET__ with the shared dispatch secret value.
-- The secret value is sent as an HTTP header; do not commit the substituted SQL.

drop trigger if exists scoutcapture_dispatch_qa95_report_package_on_snapshot on public.session_snapshots;
drop trigger if exists scoutcapture_dispatch_test_org_report_package_on_snapshot on public.session_snapshots;
drop trigger if exists scoutcapture_dispatch_report_package_on_snapshot on public.session_snapshots;

create trigger scoutcapture_dispatch_report_package_on_snapshot
after insert on public.session_snapshots
for each row
when (
  new.snapshot_kind = 'completed'
  and new.session_status = 'completed'
  and coalesce(new.is_sealed, false) is true
  and new.deleted_at is null
)
execute function supabase_functions.http_request(
  'https://chlvazmtucoszicehtnm.functions.supabase.co/report-package-dispatch',
  'POST',
  '{"Content-Type":"application/json","x-scoutcapture-report-trigger-secret":"__REPORT_PACKAGE_DISPATCH_SECRET__"}',
  '{}',
  '5000'
);

-- Source: scout-site@ef46714:supabase/migrations/202609280002_account_deletion_snapshot_redactions.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- A resumable scan and journal for removing account attribution from retained
-- session snapshots. Applied only after the request migration.
alter table public.account_deletion_requests
    add column if not exists snapshot_scan_cursor uuid,
    add column if not exists snapshot_scan_complete boolean not null default false;

create table if not exists public.account_deletion_snapshot_redactions (
    request_id uuid not null references public.account_deletion_requests(id) on delete cascade,
    snapshot_id uuid not null,
    bucket_id text not null check (bucket_id = 'scoutcapture-session-snapshots'),
    object_name text not null,
    temporary_name text not null,
    original_sha256 text not null check (original_sha256 ~ '^[0-9a-f]{64}$'),
    redacted_sha256 text not null check (redacted_sha256 ~ '^[0-9a-f]{64}$'),
    raw_session_json_sha256 text not null check (raw_session_json_sha256 ~ '^[0-9a-f]{64}$'),
    payload_byte_size bigint not null check (payload_byte_size > 0),
    redacted_manifest jsonb not null,
    status text not null default 'pending' check (status in ('pending', 'complete')),
    primary key (request_id, snapshot_id)
);

alter table public.account_deletion_snapshot_redactions enable row level security;
revoke all on public.account_deletion_snapshot_redactions from anon, authenticated;
grant select, insert, update, delete on public.account_deletion_snapshot_redactions to service_role;

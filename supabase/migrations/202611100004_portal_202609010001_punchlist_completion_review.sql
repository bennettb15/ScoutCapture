-- Source: scout-site@ef46714:supabase/migrations/202609010001_punchlist_completion_review.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Client completion submissions and Scout/admin review for punchlist items.
-- Append-only activity keeps original shots, report packages, and sealed snapshots unchanged.

alter table public.punchlist_activity
    add column if not exists storage_bucket text,
    add column if not exists storage_path text,
    add column if not exists filename text,
    add column if not exists mime_type text,
    add column if not exists byte_size bigint;

alter table public.punchlist_activity
    drop constraint if exists punchlist_activity_type_check;

alter table public.punchlist_activity
    add constraint punchlist_activity_type_check
    check (
        activity_type in (
            'note_added',
            'status_changed',
            'priority_changed',
            'due_date_changed',
            'trade_changed',
            'completion_submitted',
            'completion_approved',
            'completion_rejected'
        )
    );

alter table public.punchlist_activity
    drop constraint if exists punchlist_activity_completion_attachment_check;

alter table public.punchlist_activity
    add constraint punchlist_activity_completion_attachment_check
    check (
        activity_type <> 'completion_submitted'
        or (
            nullif(trim(coalesce(storage_bucket, '')), '') is not null
            and nullif(trim(coalesce(storage_path, '')), '') is not null
            and nullif(trim(coalesce(filename, '')), '') is not null
            and mime_type like 'image/%'
            and byte_size > 0
        )
    );

create index if not exists idx_punchlist_activity_completion_review
    on public.punchlist_activity (observation_id, activity_type, created_at desc)
    where deleted_at is null
      and activity_type in ('completion_submitted', 'completion_approved', 'completion_rejected');

comment on column public.punchlist_activity.storage_bucket is
'Optional attachment storage bucket for append-only punchlist completion submissions.';

comment on column public.punchlist_activity.storage_path is
'Optional attachment storage path for append-only punchlist completion submissions.';

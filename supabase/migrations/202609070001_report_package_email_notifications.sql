create table if not exists public.report_package_email_notifications (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    property_id uuid not null references public.properties(id),
    session_id uuid not null references public.sessions(id),
    snapshot_id uuid not null references public.session_snapshots(id),
    package_id uuid not null,
    notification_type text not null,
    recipient_user_id uuid not null references public.users_profile(id),
    recipient_email text not null,
    recipient_name text,
    recipient_role text,
    status text not null default 'pending',
    provider text not null default 'resend',
    provider_message_id text,
    idempotency_key text not null,
    attempt_count integer not null default 0,
    last_attempted_at timestamptz,
    sent_at timestamptz,
    last_error text,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now())
);

alter table public.report_package_email_notifications
    drop constraint if exists report_package_email_notifications_type_check;
alter table public.report_package_email_notifications
    add constraint report_package_email_notifications_type_check
    check (notification_type in ('report_package_ready'));

alter table public.report_package_email_notifications
    drop constraint if exists report_package_email_notifications_status_check;
alter table public.report_package_email_notifications
    add constraint report_package_email_notifications_status_check
    check (status in ('pending', 'sending', 'sent', 'failed', 'skipped'));

alter table public.report_package_email_notifications
    drop constraint if exists report_package_email_notifications_provider_check;
alter table public.report_package_email_notifications
    add constraint report_package_email_notifications_provider_check
    check (provider in ('resend'));

create unique index if not exists idx_report_package_email_notifications_recipient_unique
    on public.report_package_email_notifications (package_id, notification_type, recipient_user_id);

create unique index if not exists idx_report_package_email_notifications_idempotency_key_unique
    on public.report_package_email_notifications (idempotency_key);

create index if not exists idx_report_package_email_notifications_pending
    on public.report_package_email_notifications (status, created_at)
    where status in ('pending', 'failed');

create index if not exists idx_report_package_email_notifications_package
    on public.report_package_email_notifications (package_id, notification_type);

drop trigger if exists set_report_package_email_notifications_updated_at
    on public.report_package_email_notifications;
create trigger set_report_package_email_notifications_updated_at
    before update on public.report_package_email_notifications
    for each row
    execute function public.set_updated_at();

alter table public.report_package_email_notifications enable row level security;

revoke all on public.report_package_email_notifications from anon, authenticated;
grant select, insert, update, delete on public.report_package_email_notifications to service_role;

comment on table public.report_package_email_notifications is
    'Durable report-ready email outbox. One sent row per ready report package, notification type, and recipient user prevents duplicate portal-ready emails on retries.';

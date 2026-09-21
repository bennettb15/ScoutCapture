create table if not exists public.report_email_org_settings (
    org_id uuid primary key references public.orgs(id) on delete cascade,
    report_ready_enabled boolean not null default true,
    updated_by uuid references public.users_profile(id),
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.report_email_user_preferences (
    org_id uuid not null references public.orgs(id) on delete cascade,
    user_id uuid not null references public.users_profile(id) on delete cascade,
    report_ready_enabled boolean not null default true,
    updated_by uuid references public.users_profile(id),
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    primary key (org_id, user_id)
);

drop trigger if exists set_report_email_org_settings_updated_at
    on public.report_email_org_settings;
create trigger set_report_email_org_settings_updated_at
    before update on public.report_email_org_settings
    for each row
    execute function public.set_updated_at();

drop trigger if exists set_report_email_user_preferences_updated_at
    on public.report_email_user_preferences;
create trigger set_report_email_user_preferences_updated_at
    before update on public.report_email_user_preferences
    for each row
    execute function public.set_updated_at();

alter table public.report_email_org_settings enable row level security;
alter table public.report_email_user_preferences enable row level security;

revoke all on public.report_email_org_settings from anon, authenticated;
revoke all on public.report_email_user_preferences from anon, authenticated;

grant select, insert, update, delete on public.report_email_org_settings to authenticated;
grant select, insert, update, delete on public.report_email_user_preferences to authenticated;
grant select, insert, update, delete on public.report_email_org_settings to service_role;
grant select, insert, update, delete on public.report_email_user_preferences to service_role;

drop policy if exists report_email_org_settings_select_member
    on public.report_email_org_settings;
create policy report_email_org_settings_select_member
on public.report_email_org_settings
for select
to authenticated
using (public.is_org_member(org_id));

drop policy if exists report_email_org_settings_upsert_owner
    on public.report_email_org_settings;
create policy report_email_org_settings_upsert_owner
on public.report_email_org_settings
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner'])
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists report_email_org_settings_update_owner
    on public.report_email_org_settings;
create policy report_email_org_settings_update_owner
on public.report_email_org_settings
for update
to authenticated
using (public.has_org_role(org_id, array['owner']))
with check (
    public.has_org_role(org_id, array['owner'])
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists report_email_user_preferences_select_member
    on public.report_email_user_preferences;
create policy report_email_user_preferences_select_member
on public.report_email_user_preferences
for select
to authenticated
using (public.is_org_member(org_id));

drop policy if exists report_email_user_preferences_insert_owner
    on public.report_email_user_preferences;
create policy report_email_user_preferences_insert_owner
on public.report_email_user_preferences
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner'])
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists report_email_user_preferences_update_owner
    on public.report_email_user_preferences;
create policy report_email_user_preferences_update_owner
on public.report_email_user_preferences
for update
to authenticated
using (public.has_org_role(org_id, array['owner']))
with check (
    public.has_org_role(org_id, array['owner'])
    and public.updated_by_matches_actor(updated_by)
);

comment on table public.report_email_org_settings is
    'Org-level report-ready email controls. Missing rows default to enabled.';
comment on table public.report_email_user_preferences is
    'Per-user report-ready email controls within an org. Missing rows default to enabled.';

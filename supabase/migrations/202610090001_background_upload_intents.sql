-- A sealed session announces its complete photo set before file-backed background
-- transfers begin. The report worker can finish the cloud handoff after iOS
-- suspends the app, without guessing whether more photos are still coming.
create table if not exists public.session_upload_intents (
    session_id uuid primary key references public.sessions(id),
    org_id uuid not null references public.orgs(id),
    property_id uuid not null references public.properties(id),
    owner_user_id uuid not null references public.users_profile(id),
    session_type text not null check (session_type in ('full_documentation', 'punchlist_visit')),
    report_mode text not null check (report_mode in ('all', 'punchlist')),
    expected_shot_count integer not null check (expected_shot_count > 0),
    completed_snapshot_id uuid references public.session_snapshots(id),
    attempt_count integer not null default 0,
    last_attempt_at timestamptz,
    last_error text,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    check ((session_type = 'full_documentation' and report_mode = 'all')
        or (session_type = 'punchlist_visit' and report_mode = 'punchlist'))
);

create index if not exists idx_session_upload_intents_pending
    on public.session_upload_intents (created_at)
    where completed_snapshot_id is null;

alter table public.session_upload_intents enable row level security;
revoke all on public.session_upload_intents from public, anon, authenticated;
grant select on public.session_upload_intents to authenticated;
grant all on public.session_upload_intents to service_role;

drop policy if exists session_upload_intents_read_owner on public.session_upload_intents;
create policy session_upload_intents_read_owner
    on public.session_upload_intents for select to authenticated
    using (owner_user_id = auth.uid() and public.has_property_access(org_id, property_id));

create or replace function public.register_session_upload_intent(
    p_org_id uuid,
    p_property_id uuid,
    p_session_id uuid,
    p_session_type text,
    p_report_mode text,
    p_expected_shot_count integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    caller_id uuid := auth.uid();
    actual_shot_count integer;
    affected_rows integer;
begin
    if caller_id is null or not public.has_property_access(p_org_id, p_property_id) then
        raise exception 'upload_intent_access_denied';
    end if;
    if p_expected_shot_count <= 0 or not (
        (p_session_type = 'full_documentation' and p_report_mode = 'all')
        or (p_session_type = 'punchlist_visit' and p_report_mode = 'punchlist')
    ) then
        raise exception 'upload_intent_invalid_shape';
    end if;
    if not exists (
        select 1 from public.sessions s
        where s.id = p_session_id and s.org_id = p_org_id
          and s.property_id = p_property_id and s.status = 'completed'
          and s.is_sealed = true and s.deleted_at is null
    ) then
        raise exception 'upload_intent_session_not_sealed';
    end if;
    select count(*) into actual_shot_count from public.shots shot
    where shot.org_id = p_org_id and shot.property_id = p_property_id
      and shot.session_id = p_session_id and shot.deleted_at is null;
    if actual_shot_count <> p_expected_shot_count then
        raise exception 'upload_intent_shot_count_mismatch';
    end if;
    insert into public.session_upload_intents (
        session_id, org_id, property_id, owner_user_id,
        session_type, report_mode, expected_shot_count
    ) values (
        p_session_id, p_org_id, p_property_id, caller_id,
        p_session_type, p_report_mode, p_expected_shot_count
    )
    on conflict (session_id) do update set
        expected_shot_count = excluded.expected_shot_count,
        updated_at = timezone('utc', now())
    where session_upload_intents.org_id = excluded.org_id
      and session_upload_intents.property_id = excluded.property_id
      and session_upload_intents.owner_user_id = excluded.owner_user_id
      and session_upload_intents.session_type = excluded.session_type
      and session_upload_intents.report_mode = excluded.report_mode
      and session_upload_intents.expected_shot_count = excluded.expected_shot_count
      and session_upload_intents.completed_snapshot_id is null;
    get diagnostics affected_rows = row_count;
    if affected_rows <> 1 then
        raise exception 'upload_intent_already_completed_or_changed';
    end if;
end;
$$;

revoke all on function public.register_session_upload_intent(uuid, uuid, uuid, text, text, integer) from public, anon;
grant execute on function public.register_session_upload_intent(uuid, uuid, uuid, text, text, integer) to authenticated;

alter table public.session_snapshots
    add column if not exists upload_intent_session_id uuid references public.session_upload_intents(session_id);
create unique index if not exists idx_session_snapshots_upload_intent_once
    on public.session_snapshots (upload_intent_session_id)
    where upload_intent_session_id is not null and deleted_at is null;

-- Called only by the service worker, after the app has confirmed every photo.
-- The row lock prevents replacing a newer user's occupancy or pending export.
create or replace function public.prepare_background_upload_handoff(p_session_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    intent public.session_upload_intents%rowtype;
    current_status public.property_status%rowtype;
    uploaded_count integer;
begin
    select * into intent from public.session_upload_intents
    where session_id = p_session_id for update;
    if intent.session_id is null or intent.completed_snapshot_id is not null then
        return false;
    end if;
    if not exists (
        select 1 from public.sessions s
        where s.id = p_session_id and s.org_id = intent.org_id
          and s.property_id = intent.property_id and s.status = 'completed'
          and s.is_sealed = true and s.deleted_at is null
    ) then
        return false;
    end if;
    select count(*) into uploaded_count from public.shots shot
    where shot.session_id = p_session_id and shot.org_id = intent.org_id
      and shot.property_id = intent.property_id and shot.deleted_at is null
      and shot.upload_state = 'uploaded' and shot.storage_bucket is not null
      and shot.storage_path is not null and shot.checksum_sha256 is not null;
    if uploaded_count <> intent.expected_shot_count or exists (
        select 1 from public.shots shot
        where shot.session_id = p_session_id and shot.org_id = intent.org_id
          and shot.property_id = intent.property_id and shot.deleted_at is null
          and (shot.upload_state is distinct from 'uploaded'
            or shot.storage_bucket is null or shot.storage_path is null
            or shot.checksum_sha256 is null)
    ) then
        return false;
    end if;
    select * into current_status from public.property_status
    where property_id = intent.property_id and org_id = intent.org_id for update;
    if current_status.property_id is null then
        return false;
    end if;
    if current_status.status = 'pending_export' then
        return current_status.pending_export_session_id = p_session_id;
    end if;
    if current_status.status = 'exported' then
        return false;
    end if;
    if current_status.status not in ('occupied', 'draft')
       or current_status.owner_user_id is distinct from intent.owner_user_id
       or coalesce(current_status.active_session_id, current_status.draft_session_id) is distinct from p_session_id then
        return false;
    end if;
    update public.property_status set
        status = 'pending_export',
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = p_session_id,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = intent.owner_user_id,
        status_reason = 'background_upload_handoff',
        revision = revision + 1
    where property_id = intent.property_id and org_id = intent.org_id;
    return true;
end;
$$;

revoke all on function public.prepare_background_upload_handoff(uuid) from public, anon, authenticated;
grant execute on function public.prepare_background_upload_handoff(uuid) to service_role;

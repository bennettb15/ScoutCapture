-- A fast camera draft may have photos only on its originating device. Publish
-- its ownership without pretending that those files or shot rows were uploaded.
-- The session UUID is an operational lock key until normal completion uploads
-- the material session. Local-only ownership is device-scoped: existing
-- property_status_actor_owns uses user OR device, so owner_user_id must stay
-- null here. updated_by retains the account that published the claim.
-- The originating device must explicitly release it if discarded.

alter table public.property_status
    add column if not exists local_draft_session_id uuid;

comment on column public.property_status.local_draft_session_id is
    'Session UUID for a saved draft whose photos are still only on the originating device.';
comment on column public.property_status.draft_session_id is
    'Current unresolved draft session UUID for operational locking; it may be local-only until upload.';

create or replace function public.promote_local_property_status_draft(
    target_property_id uuid,
    target_session_id uuid,
    target_device_id text,
    target_status_reason text default 'fast_local_draft_saved'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    normalized_device_id text := nullif(btrim(coalesce(target_device_id, '')), '');
    existing public.property_status%rowtype;
    result public.property_status%rowtype;
begin
    if target_session_id is null or normalized_device_id is null then
        raise exception 'Local draft requires a session and device.' using errcode = '22023';
    end if;

    if exists (
        select 1 from public.sessions session_row
        where session_row.id = target_session_id
          and (session_row.org_id <> target_org_id or session_row.property_id <> target_property_id)
    ) then
        raise exception 'Draft session belongs to another property.' using errcode = 'P0001';
    end if;
    if exists (
        select 1 from public.sessions session_row
        where session_row.id = target_session_id
          and (session_row.deleted_at is not null
               or session_row.status <> 'draft'
               or coalesce(session_row.is_sealed, false)
               or session_row.completed_at is not null)
    ) then
        raise exception 'A completed session cannot reclaim a local draft.' using errcode = 'P0001';
    end if;

    select * into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    perform public.property_status_assert_not_blocked(existing, normalized_device_id, true);
    if existing.local_draft_session_id = target_session_id
       and existing.updated_by is distinct from actor_id then
        raise exception 'Local draft belongs to another account.' using errcode = '42501';
    end if;
    if existing.status = 'draft'
       and existing.draft_session_id is distinct from target_session_id then
        raise exception 'Another unresolved draft is already present.' using errcode = 'P0001';
    end if;
    if existing.status = 'occupied'
       and not public.property_status_is_stale(existing.status, existing.heartbeat_at)
       and existing.active_session_id is distinct from target_session_id then
        raise exception 'A different capture owns this property.' using errcode = 'P0001';
    end if;

    insert into public.property_status (
        property_id, org_id, status, active_session_id, draft_session_id,
        local_draft_session_id, pending_export_session_id, last_exported_session_id,
        owner_user_id, owner_device_id, heartbeat_at, updated_by, status_reason, revision
    ) values (
        target_property_id, target_org_id, 'draft', target_session_id, target_session_id,
        target_session_id, null, existing.last_exported_session_id,
        null, normalized_device_id, timezone('utc', now()), actor_id,
        coalesce(nullif(btrim(target_status_reason), ''), 'fast_local_draft_saved'), 1
    )
    on conflict (property_id) do update
    set org_id = excluded.org_id,
        status = 'draft',
        active_session_id = excluded.active_session_id,
        draft_session_id = excluded.draft_session_id,
        local_draft_session_id = excluded.local_draft_session_id,
        pending_export_session_id = null,
        owner_user_id = null,
        owner_device_id = normalized_device_id,
        heartbeat_at = timezone('utc', now()),
        updated_by = actor_id,
        status_reason = excluded.status_reason,
        revision = public.property_status.revision + 1
    returning * into result;

    return result;
end;
$$;

create or replace function public.release_local_property_status_draft(
    target_property_id uuid,
    target_session_id uuid,
    target_device_id text
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    existing public.property_status%rowtype;
    result public.property_status%rowtype;
begin
    select * into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    if existing.property_id is null or existing.org_id <> target_org_id
       or existing.status <> 'draft'
       or existing.local_draft_session_id is distinct from target_session_id
       or existing.draft_session_id is distinct from target_session_id
       or nullif(btrim(coalesce(existing.owner_device_id, '')), '')
          is distinct from nullif(btrim(coalesce(target_device_id, '')), '')
       or existing.updated_by is distinct from actor_id then
        raise exception 'Local draft claim is not owned by this device.' using errcode = '42501';
    end if;

    update public.property_status
    set status = case when last_exported_session_id is null then 'idle' else 'exported' end,
        active_session_id = null,
        draft_session_id = null,
        local_draft_session_id = null,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = actor_id,
        status_reason = 'fast_local_draft_discarded',
        revision = revision + 1
    where property_id = target_property_id
    returning * into result;

    return result;
end;
$$;

-- Preserve a local-only draft during maintenance rebuilds. Once its session is
-- completed, sealed, or deleted, the established material rebuild takes over.
alter function public.rebuild_property_status(uuid, text)
    rename to rebuild_property_status_core;

create function public.rebuild_property_status(
    target_property_id uuid,
    target_status_reason text default 'rebuild'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    existing public.property_status%rowtype;
begin
    select * into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    if existing.org_id = target_org_id
       and existing.status = 'draft'
       and existing.local_draft_session_id is not null
       and existing.local_draft_session_id = existing.draft_session_id
       and not exists (
           select 1 from public.sessions session_row
           where session_row.id = existing.local_draft_session_id
             and (session_row.deleted_at is not null
                  or session_row.status <> 'draft'
                  or coalesce(session_row.is_sealed, false)
                  or session_row.completed_at is not null)
       ) then
        return existing;
    end if;

    return public.rebuild_property_status_core(target_property_id, target_status_reason);
end;
$$;

-- A normal occupancy release must not discard an independently saved local
-- draft. The explicit release_local_property_status_draft RPC handles discard.
alter function public.release_property_status_if_owner(uuid, text, text)
    rename to release_property_status_if_owner_core;

create function public.release_property_status_if_owner(
    target_property_id uuid,
    target_device_id text,
    target_status_reason text default 'release_if_owner'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    existing public.property_status%rowtype;
begin
    select * into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    if existing.org_id = target_org_id
       and existing.status = 'draft'
       and existing.local_draft_session_id is not null
       and existing.local_draft_session_id = existing.draft_session_id then
        if not public.property_status_actor_owns(
            existing.owner_user_id, existing.owner_device_id, target_device_id
        ) then
            raise exception 'Only the property status owner can release this row.'
                using errcode = '42501';
        end if;
        return existing;
    end if;

    return public.release_property_status_if_owner_core(
        target_property_id, target_device_id, target_status_reason
    );
end;
$$;

revoke all on function public.rebuild_property_status_core(uuid, text) from public, anon, authenticated;
revoke all on function public.rebuild_property_status(uuid, text) from public, anon;
revoke all on function public.release_property_status_if_owner_core(uuid, text, text) from public, anon, authenticated;
revoke all on function public.release_property_status_if_owner(uuid, text, text) from public, anon;
revoke all on function public.promote_local_property_status_draft(uuid, uuid, text, text) from public, anon;
revoke all on function public.release_local_property_status_draft(uuid, uuid, text) from public, anon;
grant execute on function public.rebuild_property_status(uuid, text) to authenticated;
grant execute on function public.release_property_status_if_owner(uuid, text, text) to authenticated;
grant execute on function public.promote_local_property_status_draft(uuid, uuid, text, text) to authenticated;
grant execute on function public.release_local_property_status_draft(uuid, uuid, text) to authenticated;

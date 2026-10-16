-- Manual recovery for an abandoned, zero-photo property claim. This never
-- releases a live heartbeat, another user's claim, a material draft, or upload.
create or replace function public.release_stale_property_lock(target_property_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    current_status public.property_status%rowtype;
    current_occupancy public.property_session_occupancy%rowtype;
    stale_before timestamptz := timezone('utc', now()) - interval '3 minutes';
begin
    -- All operational status transitions serialize on this row.
    select * into current_status
    from public.property_status
    where property_id = target_property_id and org_id = target_org_id
    for update;

    if current_status.property_id is null or current_status.status in ('idle', 'exported') then
        return 'already_unlocked';
    end if;
    if current_status.status not in ('occupied', 'draft') then
        return 'protected_work';
    end if;
    if current_status.owner_user_id is distinct from actor_id then
        return 'different_owner';
    end if;
    if greatest(current_status.heartbeat_at, current_status.updated_at) >= stale_before then
        return 'recent_activity';
    end if;

    select * into current_occupancy
    from public.property_session_occupancy
    where property_id = target_property_id and org_id = target_org_id
    for update;
    if current_occupancy.property_id is not null then
        if current_occupancy.occupied_by_user_id is distinct from actor_id
           or greatest(current_occupancy.occupied_at, current_occupancy.updated_at) >= stale_before then
            return 'recent_or_other_occupancy';
        end if;
    end if;

    -- Lock existing sessions before inspecting their work and clearing markers.
    perform 1 from public.sessions
    where property_id = target_property_id and org_id = target_org_id and deleted_at is null
    for update;

    if exists (
        select 1 from public.session_upload_intents intent
        where intent.property_id = target_property_id and intent.org_id = target_org_id
          and intent.completed_snapshot_id is null
    ) or exists (
        select 1 from public.sessions session_row
        where session_row.property_id = target_property_id
          and session_row.org_id = target_org_id and session_row.deleted_at is null
          and coalesce(session_row.is_sealed, false) = true
          and session_row.first_delivered_at is null
          and session_row.exported_at is null
    ) or exists (
        select 1 from public.sessions session_row
        join public.shots shot on shot.session_id = session_row.id
        where session_row.property_id = target_property_id
          and session_row.org_id = target_org_id and session_row.deleted_at is null
          and session_row.first_delivered_at is null
          and session_row.exported_at is null
          and shot.org_id = target_org_id and shot.deleted_at is null
          and coalesce(shot.lifecycle_state, 'active') not in ('retired', 'deleted')
    ) then
        return 'protected_work';
    end if;

    if exists (
        select 1 from public.sessions session_row
        where session_row.property_id = target_property_id
          and session_row.org_id = target_org_id and session_row.deleted_at is null
          and (session_row.locked_by_user_id is not null
               or nullif(btrim(coalesce(session_row.locked_by_device_id, '')), '') is not null
               or session_row.locked_at is not null)
          and (session_row.locked_by_user_id is distinct from actor_id
               or session_row.locked_at >= stale_before
               or session_row.updated_at >= stale_before)
    ) then
        return 'recent_or_other_session';
    end if;

    delete from public.property_session_occupancy
    where property_id = target_property_id and org_id = target_org_id;

    update public.sessions
    set locked_by_user_id = null,
        locked_by_device_id = null,
        locked_at = null,
        updated_by = actor_id,
        revision = revision + 1
    where property_id = target_property_id and org_id = target_org_id
      and deleted_at is null
      and (locked_by_user_id is not null
           or nullif(btrim(coalesce(locked_by_device_id, '')), '') is not null
           or locked_at is not null);

    update public.property_status
    set status = 'idle',
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = null,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = actor_id,
        status_reason = 'manual_stale_lock_release',
        revision = revision + 1
    where property_id = target_property_id and org_id = target_org_id;

    return 'released';
end;
$$;

revoke all on function public.release_stale_property_lock(uuid) from public, anon;
grant execute on function public.release_stale_property_lock(uuid) to authenticated;

-- Phase 2C-27F-Z4 Slice 7
-- Keep transient zero-photo occupancy recovery aligned with the app-side
-- coordination timeout. Occupied rows are recoverable after missed heartbeats;
-- draft and pending_export remain non-expiring operational locks.

create or replace function public.property_status_is_stale(
    target_status text,
    target_heartbeat_at timestamptz
)
returns boolean
language sql
stable
as $$
    select target_status = 'occupied'
       and (
           target_heartbeat_at is null
           or target_heartbeat_at < timezone('utc', now()) - interval '3 minutes'
       );
$$;

create or replace function public.rebuild_property_status(
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
    actor_id uuid := auth.uid();
    occupancy_row public.property_session_occupancy%rowtype;
    draft_session public.sessions%rowtype;
    pending_session public.sessions%rowtype;
    exported_session public.sessions%rowtype;
    result public.property_status%rowtype;
begin
    select session_row.*
    into draft_session
    from public.sessions session_row
    where session_row.org_id = target_org_id
      and session_row.property_id = target_property_id
      and session_row.deleted_at is null
      and session_row.status = 'draft'
      and coalesce(session_row.is_sealed, false) = false
      and exists (
          select 1
          from public.shots shot
          where shot.session_id = session_row.id
            and shot.org_id = target_org_id
            and shot.deleted_at is null
      )
    order by session_row.updated_at desc, session_row.started_at desc nulls last, session_row.id
    limit 1;

    if draft_session.id is not null then
        insert into public.property_status (
            property_id,
            org_id,
            status,
            active_session_id,
            draft_session_id,
            owner_user_id,
            owner_device_id,
            heartbeat_at,
            updated_by,
            status_reason
        )
        values (
            target_property_id,
            target_org_id,
            'draft',
            draft_session.id,
            draft_session.id,
            draft_session.locked_by_user_id,
            nullif(btrim(coalesce(draft_session.locked_by_device_id, '')), ''),
            draft_session.locked_at,
            actor_id,
            coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':draft'
        )
        on conflict (property_id) do update
        set org_id = excluded.org_id,
            status = excluded.status,
            active_session_id = excluded.active_session_id,
            draft_session_id = excluded.draft_session_id,
            pending_export_session_id = null,
            owner_user_id = excluded.owner_user_id,
            owner_device_id = excluded.owner_device_id,
            heartbeat_at = excluded.heartbeat_at,
            updated_by = excluded.updated_by,
            status_reason = excluded.status_reason,
            revision = public.property_status.revision + 1
        returning * into result;

        return result;
    end if;

    select *
    into occupancy_row
    from public.property_session_occupancy occupancy
    where occupancy.property_id = target_property_id
      and occupancy.org_id = target_org_id
      and (
          occupancy.occupied_by_user_id is not null
          or nullif(btrim(coalesce(occupancy.occupied_by_device_id, '')), '') is not null
          or occupancy.occupied_at is not null
      )
      and (
          occupancy.occupied_at is null
          or occupancy.occupied_at >= timezone('utc', now()) - interval '3 minutes'
      )
    order by occupancy.updated_at desc
    limit 1;

    if occupancy_row.property_id is not null then
        insert into public.property_status (
            property_id,
            org_id,
            status,
            active_session_id,
            owner_user_id,
            owner_device_id,
            heartbeat_at,
            updated_by,
            status_reason
        )
        values (
            target_property_id,
            target_org_id,
            'occupied',
            null,
            occupancy_row.occupied_by_user_id,
            nullif(btrim(coalesce(occupancy_row.occupied_by_device_id, '')), ''),
            occupancy_row.occupied_at,
            actor_id,
            coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':occupancy'
        )
        on conflict (property_id) do update
        set org_id = excluded.org_id,
            status = excluded.status,
            active_session_id = excluded.active_session_id,
            draft_session_id = null,
            pending_export_session_id = null,
            owner_user_id = excluded.owner_user_id,
            owner_device_id = excluded.owner_device_id,
            heartbeat_at = excluded.heartbeat_at,
            updated_by = excluded.updated_by,
            status_reason = excluded.status_reason,
            revision = public.property_status.revision + 1
        returning * into result;

        return result;
    end if;

    select session_row.*
    into pending_session
    from public.sessions session_row
    where session_row.org_id = target_org_id
      and session_row.property_id = target_property_id
      and session_row.deleted_at is null
      and session_row.status = 'completed'
      and coalesce(session_row.is_sealed, false) = true
      and session_row.first_delivered_at is null
    order by session_row.completed_at desc nulls last, session_row.updated_at desc, session_row.id
    limit 1;

    if pending_session.id is not null then
        return public.set_property_status_pending_export(
            target_property_id,
            pending_session.id,
            null,
            coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':pending_export'
        );
    end if;

    select session_row.*
    into exported_session
    from public.sessions session_row
    where session_row.org_id = target_org_id
      and session_row.property_id = target_property_id
      and session_row.deleted_at is null
      and (
          session_row.first_delivered_at is not null
          or session_row.exported_at is not null
      )
    order by coalesce(session_row.first_delivered_at, session_row.exported_at, session_row.updated_at) desc,
             session_row.id
    limit 1;

    if exported_session.id is not null then
        return public.set_property_status_exported(
            target_property_id,
            exported_session.id,
            null,
            coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':exported'
        );
    end if;

    insert into public.property_status (
        property_id,
        org_id,
        status,
        updated_by,
        status_reason
    )
    values (
        target_property_id,
        target_org_id,
        'idle',
        actor_id,
        coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':idle'
    )
    on conflict (property_id) do update
    set org_id = excluded.org_id,
        status = 'idle',
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = null,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = excluded.updated_by,
        status_reason = excluded.status_reason,
        revision = public.property_status.revision + 1
    returning * into result;

    return result;
end;
$$;

revoke all on function public.property_status_is_stale(text, timestamptz) from public;
grant execute on function public.rebuild_property_status(uuid, text) to authenticated;

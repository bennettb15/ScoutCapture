-- Phase 2C-27F-Z4 Slice 8 follow-up
-- Rebuild is the authoritative legacy normalization path for property_status.
-- It must rebuild operational state from canonical history without deleting or
-- mutating property/session/shot/history rows, and without allowing stale
-- property_status owner fields to block normalization.
--
-- Material draft reconstruction only considers sessions that are still
-- actually unresolved and shots that are still usable/visible in the app.

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
    reason_prefix text := coalesce(nullif(btrim(target_status_reason), ''), 'rebuild');
    occupancy_row public.property_session_occupancy%rowtype;
    draft_session public.sessions%rowtype;
    pending_session public.sessions%rowtype;
    exported_session public.sessions%rowtype;
    existing_status public.property_status%rowtype;
    draft_owner_user_id uuid;
    draft_owner_device_id text;
    result public.property_status%rowtype;
begin
    select *
    into existing_status
    from public.property_status
    where property_id = target_property_id
    for update;

    select session_row.*
    into draft_session
    from public.sessions session_row
    where session_row.org_id = target_org_id
      and session_row.property_id = target_property_id
      and session_row.deleted_at is null
      and session_row.status = 'draft'
      and coalesce(session_row.is_sealed, false) = false
      and session_row.completed_at is null
      and session_row.exported_at is null
      and session_row.first_delivered_at is null
      and exists (
          select 1
          from public.shots shot
          where shot.session_id = session_row.id
            and shot.org_id = target_org_id
            and shot.deleted_at is null
            and coalesce(shot.lifecycle_state, 'active') not in ('retired', 'deleted')
            and coalesce(shot.hidden_from_gallery, false) = false
      )
    order by session_row.updated_at desc, session_row.started_at desc nulls last, session_row.id
    limit 1;

    if draft_session.id is not null then
        draft_owner_user_id := coalesce(draft_session.locked_by_user_id, draft_session.updated_by, actor_id);
        draft_owner_device_id := nullif(btrim(coalesce(draft_session.locked_by_device_id, '')), '');

        insert into public.property_status (
            property_id,
            org_id,
            status,
            active_session_id,
            draft_session_id,
            pending_export_session_id,
            last_exported_session_id,
            owner_user_id,
            owner_device_id,
            heartbeat_at,
            updated_by,
            status_reason,
            revision
        )
        values (
            target_property_id,
            target_org_id,
            'draft',
            draft_session.id,
            draft_session.id,
            null,
            null,
            draft_owner_user_id,
            draft_owner_device_id,
            draft_session.locked_at,
            actor_id,
            reason_prefix || ':draft',
            1
        )
        on conflict (property_id) do update
        set org_id = excluded.org_id,
            status = excluded.status,
            active_session_id = excluded.active_session_id,
            draft_session_id = excluded.draft_session_id,
            pending_export_session_id = null,
            last_exported_session_id = null,
            owner_user_id = excluded.owner_user_id,
            owner_device_id = excluded.owner_device_id,
            heartbeat_at = excluded.heartbeat_at,
            updated_by = excluded.updated_by,
            status_reason = excluded.status_reason,
            revision = public.property_status.revision + 1
        returning * into result;

        raise log '[PropertyStatusRebuild] property_id=% before_status=% after_status=% draft_session_id=% pending_export_session_id=% last_exported_session_id=% occupancy_selected=% reason=% history_rows_modified=false',
            target_property_id,
            coalesce(existing_status.status, 'missing'),
            result.status,
            draft_session.id,
            null,
            null,
            false,
            result.status_reason;

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
      and occupancy.occupied_at >= timezone('utc', now()) - interval '3 minutes'
    order by occupancy.updated_at desc
    limit 1;

    if occupancy_row.property_id is not null then
        insert into public.property_status (
            property_id,
            org_id,
            status,
            active_session_id,
            draft_session_id,
            pending_export_session_id,
            last_exported_session_id,
            owner_user_id,
            owner_device_id,
            heartbeat_at,
            updated_by,
            status_reason,
            revision
        )
        values (
            target_property_id,
            target_org_id,
            'occupied',
            null,
            null,
            null,
            null,
            occupancy_row.occupied_by_user_id,
            nullif(btrim(coalesce(occupancy_row.occupied_by_device_id, '')), ''),
            occupancy_row.occupied_at,
            actor_id,
            reason_prefix || ':occupancy',
            1
        )
        on conflict (property_id) do update
        set org_id = excluded.org_id,
            status = excluded.status,
            active_session_id = null,
            draft_session_id = null,
            pending_export_session_id = null,
            last_exported_session_id = null,
            owner_user_id = excluded.owner_user_id,
            owner_device_id = excluded.owner_device_id,
            heartbeat_at = excluded.heartbeat_at,
            updated_by = excluded.updated_by,
            status_reason = excluded.status_reason,
            revision = public.property_status.revision + 1
        returning * into result;

        raise log '[PropertyStatusRebuild] property_id=% before_status=% after_status=% draft_session_id=% pending_export_session_id=% last_exported_session_id=% occupancy_selected=% reason=% history_rows_modified=false',
            target_property_id,
            coalesce(existing_status.status, 'missing'),
            result.status,
            null,
            null,
            null,
            true,
            result.status_reason;

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
        insert into public.property_status (
            property_id,
            org_id,
            status,
            active_session_id,
            draft_session_id,
            pending_export_session_id,
            last_exported_session_id,
            owner_user_id,
            owner_device_id,
            heartbeat_at,
            updated_by,
            status_reason,
            revision
        )
        values (
            target_property_id,
            target_org_id,
            'pending_export',
            null,
            null,
            pending_session.id,
            null,
            null,
            null,
            null,
            actor_id,
            reason_prefix || ':pending_export',
            1
        )
        on conflict (property_id) do update
        set org_id = excluded.org_id,
            status = excluded.status,
            active_session_id = null,
            draft_session_id = null,
            pending_export_session_id = excluded.pending_export_session_id,
            last_exported_session_id = null,
            owner_user_id = null,
            owner_device_id = null,
            heartbeat_at = null,
            updated_by = excluded.updated_by,
            status_reason = excluded.status_reason,
            revision = public.property_status.revision + 1
        returning * into result;

        raise log '[PropertyStatusRebuild] property_id=% before_status=% after_status=% draft_session_id=% pending_export_session_id=% last_exported_session_id=% occupancy_selected=% reason=% history_rows_modified=false',
            target_property_id,
            coalesce(existing_status.status, 'missing'),
            result.status,
            null,
            pending_session.id,
            null,
            false,
            result.status_reason;

        return result;
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
        insert into public.property_status (
            property_id,
            org_id,
            status,
            active_session_id,
            draft_session_id,
            pending_export_session_id,
            last_exported_session_id,
            owner_user_id,
            owner_device_id,
            heartbeat_at,
            updated_by,
            status_reason,
            revision
        )
        values (
            target_property_id,
            target_org_id,
            'exported',
            null,
            null,
            null,
            exported_session.id,
            null,
            null,
            null,
            actor_id,
            reason_prefix || ':exported',
            1
        )
        on conflict (property_id) do update
        set org_id = excluded.org_id,
            status = excluded.status,
            active_session_id = null,
            draft_session_id = null,
            pending_export_session_id = null,
            last_exported_session_id = excluded.last_exported_session_id,
            owner_user_id = null,
            owner_device_id = null,
            heartbeat_at = null,
            updated_by = excluded.updated_by,
            status_reason = excluded.status_reason,
            revision = public.property_status.revision + 1
        returning * into result;

        raise log '[PropertyStatusRebuild] property_id=% before_status=% after_status=% draft_session_id=% pending_export_session_id=% last_exported_session_id=% occupancy_selected=% reason=% history_rows_modified=false',
            target_property_id,
            coalesce(existing_status.status, 'missing'),
            result.status,
            null,
            null,
            exported_session.id,
            false,
            result.status_reason;

        return result;
    end if;

    insert into public.property_status (
        property_id,
        org_id,
        status,
        active_session_id,
        draft_session_id,
        pending_export_session_id,
        last_exported_session_id,
        owner_user_id,
        owner_device_id,
        heartbeat_at,
        updated_by,
        status_reason,
        revision
    )
    values (
        target_property_id,
        target_org_id,
        'idle',
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        actor_id,
        reason_prefix || ':idle',
        1
    )
    on conflict (property_id) do update
    set org_id = excluded.org_id,
        status = excluded.status,
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = null,
        last_exported_session_id = null,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = excluded.updated_by,
        status_reason = excluded.status_reason,
        revision = public.property_status.revision + 1
    returning * into result;

    raise log '[PropertyStatusRebuild] property_id=% before_status=% after_status=% draft_session_id=% pending_export_session_id=% last_exported_session_id=% occupancy_selected=% reason=% history_rows_modified=false',
        target_property_id,
        coalesce(existing_status.status, 'missing'),
        result.status,
        null,
        null,
        null,
        false,
        result.status_reason;

    return result;
end;
$$;

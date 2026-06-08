-- Phase 2C-27F-Z4 follow-up
-- Release/exit coordination must not clear a valid material draft to idle.

create or replace function public.release_property_status_if_owner(
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
    actor_id uuid := auth.uid();
    existing public.property_status%rowtype;
    material_draft_session public.sessions%rowtype;
    result public.property_status%rowtype;
begin
    select *
    into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    if existing.property_id is null then
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
            coalesce(nullif(btrim(target_status_reason), ''), 'release_if_owner_missing_row')
        )
        returning * into result;

        return result;
    end if;

    if existing.status in ('occupied', 'draft')
       and not public.property_status_actor_owns(existing.owner_user_id, existing.owner_device_id, target_device_id) then
        raise exception 'Only the property status owner can release this row.'
            using errcode = '42501';
    end if;

    if existing.status not in ('occupied', 'draft') then
        return existing;
    end if;

    select session_row.*
    into material_draft_session
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
    order by
      case
        when session_row.id = existing.draft_session_id then 0
        when session_row.id = existing.active_session_id then 1
        else 2
      end,
      session_row.updated_at desc,
      session_row.started_at desc nulls last,
      session_row.id
    limit 1;

    if material_draft_session.id is not null then
        update public.property_status
        set status = 'draft',
            active_session_id = material_draft_session.id,
            draft_session_id = material_draft_session.id,
            pending_export_session_id = null,
            owner_user_id = existing.owner_user_id,
            owner_device_id = nullif(btrim(coalesce(existing.owner_device_id, '')), ''),
            heartbeat_at = existing.heartbeat_at,
            updated_by = actor_id,
            status_reason = coalesce(nullif(btrim(target_status_reason), ''), 'release_if_owner') || ':material_draft_preserved',
            revision = revision + 1
        where property_id = target_property_id
        returning * into result;

        return result;
    end if;

    update public.property_status
    set status = 'idle',
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = null,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = actor_id,
        status_reason = coalesce(nullif(btrim(target_status_reason), ''), 'release_if_owner'),
        revision = revision + 1
    where property_id = target_property_id
    returning * into result;

    return result;
end;
$$;

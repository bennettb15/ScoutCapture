-- Phase 2C-27F-Z4 Slice 7
-- Zero-photo occupancy claims may reference a local-first transient session id
-- before the session row exists remotely. Keep strict session validation in the
-- material draft, pending export, and exported RPCs; claim_property_status only
-- records current operational occupancy.

create or replace function public.claim_property_status(
    target_property_id uuid,
    target_session_id uuid,
    target_device_id text,
    target_status_reason text default 'claim_property'
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
    select *
    into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    perform public.property_status_assert_not_blocked(existing, target_device_id, true);

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
        target_session_id,
        null,
        null,
        null,
        actor_id,
        nullif(btrim(coalesce(target_device_id, '')), ''),
        timezone('utc', now()),
        actor_id,
        coalesce(nullif(btrim(target_status_reason), ''), 'claim_property'),
        1
    )
    on conflict (property_id) do update
    set org_id = excluded.org_id,
        status = excluded.status,
        active_session_id = excluded.active_session_id,
        draft_session_id = null,
        pending_export_session_id = null,
        last_exported_session_id = property_status.last_exported_session_id,
        owner_user_id = excluded.owner_user_id,
        owner_device_id = excluded.owner_device_id,
        heartbeat_at = excluded.heartbeat_at,
        updated_by = excluded.updated_by,
        status_reason = excluded.status_reason,
        revision = public.property_status.revision + 1
    returning * into result;

    return result;
end;
$$;

grant execute on function public.claim_property_status(uuid, uuid, text, text) to authenticated;

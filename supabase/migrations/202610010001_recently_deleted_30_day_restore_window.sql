-- A deleted item is recoverable for 30 full days. Older rows remain available
-- to the retention worker for durable media and record cleanup.

create or replace function public.restore_property(target_property_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid;
    target_deleted_at timestamptz;
    actor_id uuid := auth.uid();
begin
    if actor_id is null then
        raise exception 'Authenticated user required.' using errcode = '28000';
    end if;

    select property.org_id, property.deleted_at
    into target_org_id, target_deleted_at
    from public.properties property
    where property.id = target_property_id
    for update;

    if target_org_id is null then
        raise exception 'Property not found.' using errcode = 'P0002';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can restore properties.' using errcode = '42501';
    end if;

    if target_deleted_at is null then
        return;
    end if;

    if target_deleted_at <= now() - interval '30 days' then
        raise exception 'The 30-day property recovery period has expired.' using errcode = 'P0001';
    end if;

    update public.properties
    set deleted_at = null,
        updated_at = timezone('utc', now()),
        updated_by = actor_id,
        revision = revision + 1
    where id = target_property_id;
end;
$$;

create or replace function public.fetch_recently_deleted_properties(target_org_id uuid)
returns table (
    id uuid, org_id uuid, name text, client_name text,
    address_line1 text, address_line2 text, city text, state text,
    postal_code text, country_code text, is_archived boolean,
    deleted_at timestamptz, updated_at timestamptz, revision bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if auth.uid() is null then
        raise exception 'Authenticated user required.' using errcode = '28000';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can fetch recently deleted properties.' using errcode = '42501';
    end if;

    return query
    select property.id, property.org_id, property.name,
           property.client_name, property.address_line1, property.address_line2,
           property.city, property.state, property.postal_code,
           property.country_code, property.is_archived, property.deleted_at,
           property.updated_at, property.revision
    from public.properties property
    where property.org_id = target_org_id
      and property.deleted_at > now() - interval '30 days'
    order by property.deleted_at desc, property.updated_at desc, property.id;
end;
$$;

create or replace function public.restore_session(target_session_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid;
    target_property_id uuid;
    target_deleted_at timestamptz;
    actor_id uuid := auth.uid();
begin
    if actor_id is null then
        raise exception 'Authenticated user required.' using errcode = '28000';
    end if;

    select session_row.org_id, session_row.property_id, session_row.deleted_at
    into target_org_id, target_property_id, target_deleted_at
    from public.sessions session_row
    where session_row.id = target_session_id
    for update;

    if target_org_id is null then
        raise exception 'Session not found.' using errcode = 'P0002';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can restore sessions.' using errcode = '42501';
    end if;

    if not public.has_property_access(target_org_id, target_property_id) then
        raise exception 'Session property access required.' using errcode = '42501';
    end if;

    if target_deleted_at is null then
        return;
    end if;

    if target_deleted_at <= now() - interval '30 days' then
        raise exception 'The 30-day session recovery period has expired.' using errcode = 'P0001';
    end if;

    update public.sessions
    set deleted_at = null,
        updated_at = timezone('utc', now()),
        updated_by = actor_id,
        revision = revision + 1
    where id = target_session_id;
end;
$$;

create or replace function public.fetch_recently_deleted_sessions(
    target_org_id uuid,
    target_property_id uuid default null
)
returns table (
    id uuid, org_id uuid, property_id uuid, status text,
    started_at timestamptz, ended_at timestamptz, exported_at timestamptz,
    is_sealed boolean, first_delivered_at timestamptz,
    re_export_expires_at timestamptz, notes text,
    deleted_at timestamptz, updated_at timestamptz,
    updated_by uuid, revision bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if auth.uid() is null then
        raise exception 'Authenticated user required.' using errcode = '28000';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can fetch recently deleted sessions.' using errcode = '42501';
    end if;

    if target_property_id is not null
       and not public.has_property_access(target_org_id, target_property_id) then
        raise exception 'Session property access required.' using errcode = '42501';
    end if;

    return query
    select session_row.id, session_row.org_id, session_row.property_id,
           session_row.status, session_row.started_at,
           session_row.completed_at as ended_at, session_row.exported_at,
           session_row.is_sealed, session_row.first_delivered_at,
           session_row.re_export_expires_at, session_row.notes,
           session_row.deleted_at, session_row.updated_at,
           session_row.updated_by, session_row.revision
    from public.sessions session_row
    where session_row.org_id = target_org_id
      and session_row.deleted_at > now() - interval '30 days'
      and (target_property_id is null or session_row.property_id = target_property_id)
      and public.has_property_access(target_org_id, session_row.property_id)
    order by session_row.deleted_at desc, session_row.updated_at desc, session_row.id;
end;
$$;

revoke all on function public.restore_property(uuid) from public;
revoke all on function public.fetch_recently_deleted_properties(uuid) from public;
revoke all on function public.restore_session(uuid) from public;
revoke all on function public.fetch_recently_deleted_sessions(uuid, uuid) from public;
grant execute on function public.restore_property(uuid) to authenticated;
grant execute on function public.fetch_recently_deleted_properties(uuid) to authenticated;
grant execute on function public.restore_session(uuid) to authenticated;
grant execute on function public.fetch_recently_deleted_sessions(uuid, uuid) to authenticated;

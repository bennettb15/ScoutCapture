alter table public.sessions
    add column if not exists exported_at timestamptz,
    add column if not exists is_sealed boolean not null default false,
    add column if not exists first_delivered_at timestamptz,
    add column if not exists re_export_expires_at timestamptz,
    add column if not exists notes text;

create or replace function public.soft_delete_session(target_session_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid;
    target_property_id uuid;
    actor_id uuid := auth.uid();
begin
    if actor_id is null then
        raise exception 'Authenticated user required.'
            using errcode = '28000';
    end if;

    select session_row.org_id,
           session_row.property_id
    into target_org_id,
         target_property_id
    from public.sessions session_row
    where session_row.id = target_session_id;

    if target_org_id is null then
        raise exception 'Session not found.'
            using errcode = 'P0002';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can soft delete sessions.'
            using errcode = '42501';
    end if;

    if not public.has_property_access(target_org_id, target_property_id) then
        raise exception 'Session property access required.'
            using errcode = '42501';
    end if;

    update public.sessions
    set deleted_at = timezone('utc', now()),
        updated_at = timezone('utc', now()),
        updated_by = actor_id,
        revision = revision + 1
    where id = target_session_id
      and deleted_at is null;
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
    actor_id uuid := auth.uid();
begin
    if actor_id is null then
        raise exception 'Authenticated user required.'
            using errcode = '28000';
    end if;

    select session_row.org_id,
           session_row.property_id
    into target_org_id,
         target_property_id
    from public.sessions session_row
    where session_row.id = target_session_id;

    if target_org_id is null then
        raise exception 'Session not found.'
            using errcode = 'P0002';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can restore sessions.'
            using errcode = '42501';
    end if;

    if not public.has_property_access(target_org_id, target_property_id) then
        raise exception 'Session property access required.'
            using errcode = '42501';
    end if;

    update public.sessions
    set deleted_at = null,
        updated_at = timezone('utc', now()),
        updated_by = actor_id,
        revision = revision + 1
    where id = target_session_id
      and deleted_at is not null;
end;
$$;

create or replace function public.fetch_recently_deleted_sessions(
    target_org_id uuid,
    target_property_id uuid default null
)
returns table (
    id uuid,
    org_id uuid,
    property_id uuid,
    status text,
    started_at timestamptz,
    ended_at timestamptz,
    exported_at timestamptz,
    is_sealed boolean,
    first_delivered_at timestamptz,
    re_export_expires_at timestamptz,
    notes text,
    deleted_at timestamptz,
    updated_at timestamptz,
    updated_by uuid,
    revision bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if auth.uid() is null then
        raise exception 'Authenticated user required.'
            using errcode = '28000';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can fetch recently deleted sessions.'
            using errcode = '42501';
    end if;

    if target_property_id is not null
       and not public.has_property_access(target_org_id, target_property_id) then
        raise exception 'Session property access required.'
            using errcode = '42501';
    end if;

    return query
    select session_row.id,
           session_row.org_id,
           session_row.property_id,
           session_row.status,
           session_row.started_at,
           session_row.completed_at as ended_at,
           session_row.exported_at,
           session_row.is_sealed,
           session_row.first_delivered_at,
           session_row.re_export_expires_at,
           session_row.notes,
           session_row.deleted_at,
           session_row.updated_at,
           session_row.updated_by,
           session_row.revision
    from public.sessions session_row
    where session_row.org_id = target_org_id
      and session_row.deleted_at is not null
      and (target_property_id is null or session_row.property_id = target_property_id)
      and public.has_property_access(target_org_id, session_row.property_id)
    order by session_row.deleted_at desc, session_row.updated_at desc, session_row.id;
end;
$$;

revoke all on function public.soft_delete_session(uuid) from public;
revoke all on function public.restore_session(uuid) from public;
revoke all on function public.fetch_recently_deleted_sessions(uuid, uuid) from public;

grant execute on function public.soft_delete_session(uuid) to authenticated;
grant execute on function public.restore_session(uuid) to authenticated;
grant execute on function public.fetch_recently_deleted_sessions(uuid, uuid) to authenticated;

alter table public.properties
    add column if not exists is_archived boolean not null default false;

create or replace function public.property_has_active_occupancy(target_property_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select to_regclass('public.property_session_occupancy') is not null
        and exists (
            select 1
            from public.property_session_occupancy occupancy
            where occupancy.property_id = target_property_id
              and (
                  occupancy.occupied_by_user_id is not null
                  or nullif(btrim(coalesce(occupancy.occupied_by_device_id, '')), '') is not null
                  or occupancy.occupied_at is not null
              )
        );
$$;

create or replace function public.soft_delete_property(target_property_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid;
    actor_id uuid := auth.uid();
begin
    if actor_id is null then
        raise exception 'Authenticated user required.'
            using errcode = '28000';
    end if;

    select property.org_id
    into target_org_id
    from public.properties property
    where property.id = target_property_id;

    if target_org_id is null then
        raise exception 'Property not found.'
            using errcode = 'P0002';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can soft delete properties.'
            using errcode = '42501';
    end if;

    if public.property_has_active_occupancy(target_property_id) then
        raise exception 'Property has active occupancy and cannot be soft deleted.'
            using errcode = 'P0001';
    end if;

    update public.properties
    set deleted_at = coalesce(deleted_at, timezone('utc', now())),
        updated_at = timezone('utc', now()),
        updated_by = actor_id,
        revision = revision + case when deleted_at is null then 1 else 0 end
    where id = target_property_id;
end;
$$;

create or replace function public.restore_property(target_property_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid;
    actor_id uuid := auth.uid();
begin
    if actor_id is null then
        raise exception 'Authenticated user required.'
            using errcode = '28000';
    end if;

    select property.org_id
    into target_org_id
    from public.properties property
    where property.id = target_property_id;

    if target_org_id is null then
        raise exception 'Property not found.'
            using errcode = 'P0002';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can restore properties.'
            using errcode = '42501';
    end if;

    update public.properties
    set deleted_at = null,
        updated_at = timezone('utc', now()),
        updated_by = actor_id,
        revision = revision + case when deleted_at is not null then 1 else 0 end
    where id = target_property_id;
end;
$$;

create or replace function public.fetch_recently_deleted_properties(target_org_id uuid)
returns table (
    id uuid,
    org_id uuid,
    name text,
    client_name text,
    address_line1 text,
    address_line2 text,
    city text,
    state text,
    postal_code text,
    country_code text,
    is_archived boolean,
    deleted_at timestamptz,
    updated_at timestamptz,
    revision bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
    select_sql text;
    client_name_expr text := 'null::text';
    address_line2_expr text := 'null::text';
    country_code_expr text := 'null::text';
begin
    if auth.uid() is null then
        raise exception 'Authenticated user required.'
            using errcode = '28000';
    end if;

    if not public.has_org_role(target_org_id, array['owner', 'manager']) then
        raise exception 'Only an owner or manager can fetch recently deleted properties.'
            using errcode = '42501';
    end if;

    if exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'properties'
          and column_name = 'client_name'
    ) then
        client_name_expr := 'property.client_name';
    end if;

    if exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'properties'
          and column_name = 'address_line2'
    ) then
        address_line2_expr := 'property.address_line2';
    end if;

    if exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'properties'
          and column_name = 'country_code'
    ) then
        country_code_expr := 'property.country_code';
    end if;

    select_sql := format(
        'select property.id,
                property.org_id,
                property.name,
                %s as client_name,
                property.address_line1,
                %s as address_line2,
                property.city,
                property.state,
                property.postal_code,
                %s as country_code,
                property.is_archived,
                property.deleted_at,
                property.updated_at,
                property.revision
           from public.properties property
          where property.org_id = $1
            and property.deleted_at is not null
          order by property.deleted_at desc, property.updated_at desc, property.id',
        client_name_expr,
        address_line2_expr,
        country_code_expr
    );

    return query execute select_sql using target_org_id;
end;
$$;

revoke all on function public.property_has_active_occupancy(uuid) from public;
revoke all on function public.soft_delete_property(uuid) from public;
revoke all on function public.restore_property(uuid) from public;
revoke all on function public.fetch_recently_deleted_properties(uuid) from public;

grant execute on function public.soft_delete_property(uuid) to authenticated;
grant execute on function public.restore_property(uuid) to authenticated;
grant execute on function public.fetch_recently_deleted_properties(uuid) to authenticated;

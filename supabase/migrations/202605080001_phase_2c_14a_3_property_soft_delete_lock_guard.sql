create or replace function public.property_has_active_occupancy(target_property_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select (
        to_regclass('public.property_session_occupancy') is not null
        and exists (
            select 1
            from public.property_session_occupancy occupancy
            where occupancy.property_id = target_property_id
              and (
                  occupancy.occupied_by_user_id is not null
                  or nullif(btrim(coalesce(occupancy.occupied_by_device_id, '')), '') is not null
                  or occupancy.occupied_at is not null
              )
        )
    )
    or exists (
        select 1
        from public.sessions session_row
        where session_row.property_id = target_property_id
          and session_row.deleted_at is null
          and (
              session_row.locked_by_user_id is not null
              or nullif(btrim(coalesce(session_row.locked_by_device_id, '')), '') is not null
              or session_row.locked_at is not null
          )
    );
$$;

revoke all on function public.property_has_active_occupancy(uuid) from public;

-- Replace the retention finalizer after the portal punchlist activity FK was
-- found in the live database. Run after 202610010002; this defines a function
-- and does not purge data by itself.
-- Only the service role may finalize a non-archived property after its 30-day
-- recovery window. Storage objects must be removed through the Storage API first.
create or replace function public.finalize_expired_property_purge(target_property_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    target_deleted_at timestamptz;
    target_is_archived boolean;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'Service role required.' using errcode = '42501';
    end if;

    select deleted_at, is_archived
    into target_deleted_at, target_is_archived
    from public.properties
    where id = target_property_id
    for update;

    if not found then
        return false;
    end if;
    if target_is_archived then
        raise exception 'Archived properties are retained.' using errcode = 'P0001';
    end if;
    if target_deleted_at is null
       or target_deleted_at > now() - interval '30 days' then
        raise exception 'Property recovery period has not expired.' using errcode = 'P0001';
    end if;
    if public.property_has_active_occupancy(target_property_id) then
        raise exception 'Property has active occupancy.' using errcode = 'P0001';
    end if;

    if to_regclass('public.punchlist_activity') is not null then
        execute 'delete from public.punchlist_activity where property_id = $1'
        using target_property_id;
    end if;
    delete from public.observation_updates where property_id = target_property_id;
    delete from public.observations where property_id = target_property_id;
    if to_regclass('public.report_package_email_notifications') is not null then
        execute 'delete from public.report_package_email_notifications where property_id = $1'
        using target_property_id;
    end if;
    delete from public.report_package_files where property_id = target_property_id;
    delete from public.report_packages where property_id = target_property_id;
    delete from public.temporary_exports where property_id = target_property_id;
    update public.session_snapshots
    set supersedes_snapshot_id = null,
        superseded_by_snapshot_id = null
    where property_id = target_property_id;
    delete from public.session_snapshots where property_id = target_property_id;
    delete from public.shots where property_id = target_property_id;
    delete from public.session_events where property_id = target_property_id;
    delete from public.sessions where property_id = target_property_id;
    delete from public.property_access_grants where property_id = target_property_id;
    delete from public.properties where id = target_property_id;
    return true;
end;
$$;

revoke all on function public.finalize_expired_property_purge(uuid) from public, anon, authenticated;
grant execute on function public.finalize_expired_property_purge(uuid) to service_role;

-- One-time lock release for the single approved deleted Test Org property
-- QA Test 9.17. Run only after explicit review of this exact operation.
-- This does not delete the property, its sessions, or any Storage objects.
-- The exact inventory checks make a changed or newly active lock fail closed.
begin;

do $$
declare
    target_id constant uuid := 'dd564834-bf66-429f-91ae-b6bc55d27adc';
    expected_org constant uuid := 'd4ba94ff-25e1-4072-aa79-9a548fcb3008';
    expected_deleted_at constant timestamptz := '2026-09-23 13:55:07.734114+00';
    property_name text;
    property_org uuid;
    property_deleted_at timestamptz;
    property_archived boolean;
    occupancy_at timestamptz;
    occupancy_updated_at timestamptz;
    locked_count integer;
    latest_locked_at timestamptz;
    latest_locked_session_update timestamptz;
    changed_count integer;
begin
    select p.name, p.org_id, p.deleted_at, p.is_archived
      into property_name, property_org, property_deleted_at, property_archived
      from public.properties p
     where p.id = target_id
     for update;
    if not found or property_name is distinct from 'QA Test 9.17'
       or property_org is distinct from expected_org
       or property_deleted_at is distinct from expected_deleted_at
       or property_archived is distinct from false then
        raise exception 'QA Test 9.17 no longer matches the approved deleted property.';
    end if;

    select o.occupied_at, o.updated_at
      into occupancy_at, occupancy_updated_at
      from public.property_session_occupancy o
     where o.property_id = target_id
     for update;
    if not found
       or occupancy_at is distinct from '2026-09-20 01:50:57+00'::timestamptz
       or occupancy_updated_at is distinct from '2026-09-20 01:50:58.349686+00'::timestamptz then
        raise exception 'QA Test 9.17 occupancy changed since review.';
    end if;

    perform 1 from public.sessions s
     where s.property_id = target_id and s.deleted_at is null
       and (s.locked_by_user_id is not null
            or nullif(btrim(coalesce(s.locked_by_device_id, '')), '') is not null
            or s.locked_at is not null)
     for update;
    select count(*), max(s.locked_at), max(s.updated_at)
      into locked_count, latest_locked_at, latest_locked_session_update
      from public.sessions s
     where s.property_id = target_id and s.deleted_at is null
       and (s.locked_by_user_id is not null
            or nullif(btrim(coalesce(s.locked_by_device_id, '')), '') is not null
            or s.locked_at is not null);
    if locked_count <> 2
       or latest_locked_at is distinct from '2026-09-15 13:58:37+00'::timestamptz
       or latest_locked_session_update is distinct from '2026-09-20 01:42:32.649241+00'::timestamptz
       or exists (
           select 1 from public.sessions s
            where s.property_id = target_id and s.deleted_at is null
              and (s.locked_by_user_id is not null
                   or nullif(btrim(coalesce(s.locked_by_device_id, '')), '') is not null
                   or s.locked_at is not null)
              and (s.updated_at > property_deleted_at
                   or s.locked_at > property_deleted_at)
       ) then
        raise exception 'QA Test 9.17 session locks changed since review.';
    end if;

    delete from public.property_session_occupancy
     where property_id = target_id;
    get diagnostics changed_count = row_count;
    if changed_count <> 1 then
        raise exception 'Expected one occupancy row to be released.';
    end if;

    update public.sessions
       set locked_by_user_id = null,
           locked_by_device_id = null,
           locked_at = null
     where property_id = target_id and deleted_at is null
       and (locked_by_user_id is not null
            or nullif(btrim(coalesce(locked_by_device_id, '')), '') is not null
            or locked_at is not null);
    get diagnostics changed_count = row_count;
    if changed_count <> 2 or public.property_has_active_occupancy(target_id) then
        raise exception 'QA Test 9.17 still has active occupancy; transaction rolled back.';
    end if;
end;
$$;

commit;

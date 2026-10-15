-- One-time repair for the two reviewed QA property_status rows.
-- Run only after approval. This does not delete properties, sessions, or photos.
-- Any new heartbeat, session, or occupancy makes the entire transaction abort.
begin isolation level serializable;

do $$
declare
    changed_rows integer;
begin
    update public.property_status status_row
    set status = 'idle',
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = null,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        status_reason = 'qa_orphan_status_released_20261015',
        revision = status_row.revision + 1
    from public.properties property_row
    where property_row.id = status_row.property_id
      and property_row.deleted_at is null
      and (
          (property_row.name = 'QA Test 10.12'
           and status_row.active_session_id = '59cb2688-0cd9-4a7f-abb7-9f22a9ff6e43'::uuid
           and status_row.heartbeat_at = '2026-10-15 10:49:27.428275+00'::timestamptz)
          or
          (property_row.name = 'QA Test 10.13'
           and status_row.active_session_id = 'ff34f893-edc1-4600-b1d3-ea213b55645e'::uuid
           and status_row.heartbeat_at = '2026-10-15 10:49:27.366122+00'::timestamptz)
      )
      and status_row.status = 'occupied'
      and status_row.status_reason = 'entry_gate_current_user_heartbeat'
      and status_row.owner_device_id = 'd425c797-3bfa-4f98-85c7-03d9446936bb'
      and status_row.draft_session_id is null
      and status_row.pending_export_session_id is null
      and status_row.heartbeat_at < timezone('utc', now()) - interval '3 minutes'
      and not exists (
          select 1 from public.sessions session_row
          where session_row.id = status_row.active_session_id
      )
      and not exists (
          select 1 from public.property_session_occupancy occupancy
          where occupancy.property_id = status_row.property_id
            and (
                occupancy.occupied_by_user_id is not null
                or nullif(btrim(coalesce(occupancy.occupied_by_device_id, '')), '') is not null
                or occupancy.occupied_at is not null
            )
      )
      and not exists (
          select 1 from public.sessions session_row
          where session_row.property_id = status_row.property_id
            and session_row.deleted_at is null
            and (
                (session_row.status = 'draft' and coalesce(session_row.is_sealed, false) = false)
                or (session_row.status = 'completed' and session_row.first_delivered_at is null)
            )
      );

    get diagnostics changed_rows = row_count;
    if changed_rows <> 2 then
        raise exception 'Expected exactly two unchanged orphaned QA status rows; transaction rolled back (matched %).', changed_rows;
    end if;
end;
$$;

commit;

select property_row.name, status_row.status, status_row.active_session_id,
       status_row.draft_session_id, status_row.pending_export_session_id,
       status_row.status_reason
from public.property_status status_row
join public.properties property_row on property_row.id = status_row.property_id
where status_row.status_reason = 'qa_orphan_status_released_20261015'
  and property_row.name in ('QA Test 10.12', 'QA Test 10.13')
order by property_row.name;

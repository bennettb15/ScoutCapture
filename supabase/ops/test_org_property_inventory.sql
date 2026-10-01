-- Read only. Run in the Supabase SQL Editor and export the result as CSV.
-- Confirm the five visible QA Test 10.11–10.15 properties before any purge.
select
    o.id as org_id,
    o.name as org_name,
    p.id as property_id,
    p.name as property_name,
    p.is_archived,
    p.deleted_at,
    case
        when p.deleted_at is not null then 'deleted'
        when p.is_archived then 'archived'
        else 'active'
    end as property_state,
    (select count(*) from public.sessions s where s.property_id = p.id) as session_count,
    (select count(*) from public.shots sh where sh.property_id = p.id) as photo_count,
    (select count(*) from public.session_snapshots ss where ss.property_id = p.id) as snapshot_count,
    (select count(*) from public.report_package_files rf where rf.property_id = p.id) as report_file_count,
    (select count(*) from public.temporary_exports te where te.property_id = p.id) as temporary_export_count
from public.orgs o
join public.properties p on p.org_id = o.id
where o.name = 'Test Org'
  and o.deleted_at is null
order by o.id, p.deleted_at nulls first, p.name, p.id;

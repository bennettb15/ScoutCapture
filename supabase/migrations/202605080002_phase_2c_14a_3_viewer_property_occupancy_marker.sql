drop policy if exists property_session_occupancy_insert_owner_manager_field on public.property_session_occupancy;
create policy property_session_occupancy_insert_member
on public.property_session_occupancy
for insert
to authenticated
with check (
    public.has_property_access(org_id, property_id)
    and public.property_belongs_to_org(property_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists property_session_occupancy_update_owner_manager_field on public.property_session_occupancy;
create policy property_session_occupancy_update_member
on public.property_session_occupancy
for update
to authenticated
using (
    public.has_property_access(org_id, property_id)
)
with check (
    public.has_property_access(org_id, property_id)
    and public.property_belongs_to_org(property_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists property_session_occupancy_delete_owner_manager_field on public.property_session_occupancy;
create policy property_session_occupancy_delete_member
on public.property_session_occupancy
for delete
to authenticated
using (
    public.has_property_access(org_id, property_id)
    and public.property_belongs_to_org(property_id, org_id)
);

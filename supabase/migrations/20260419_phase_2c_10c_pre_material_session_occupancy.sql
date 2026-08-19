create table if not exists public.property_session_occupancy (
    property_id uuid primary key references public.properties(id) on delete cascade,
    org_id uuid not null references public.orgs(id),
    occupied_by_user_id uuid references public.users_profile(id),
    occupied_by_device_id text,
    occupied_at timestamptz,
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid references public.users_profile(id)
);

create trigger set_property_session_occupancy_updated_at
    before update on public.property_session_occupancy
    for each row
    execute function public.set_updated_at();

create index if not exists idx_property_session_occupancy_org_property
    on public.property_session_occupancy (org_id, property_id);

alter table public.property_session_occupancy enable row level security;

grant select, insert, update, delete on public.property_session_occupancy to authenticated;

drop policy if exists property_session_occupancy_select_member on public.property_session_occupancy;
create policy property_session_occupancy_select_member
on public.property_session_occupancy
for select
to authenticated
using (public.is_org_member(org_id));

drop policy if exists property_session_occupancy_insert_owner_manager_field on public.property_session_occupancy;
create policy property_session_occupancy_insert_owner_manager_field
on public.property_session_occupancy
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists property_session_occupancy_update_owner_manager_field on public.property_session_occupancy;
create policy property_session_occupancy_update_owner_manager_field
on public.property_session_occupancy
for update
to authenticated
using (public.has_org_role(org_id, array['owner', 'manager', 'field']))
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists property_session_occupancy_delete_owner_manager_field on public.property_session_occupancy;
create policy property_session_occupancy_delete_owner_manager_field
on public.property_session_occupancy
for delete
to authenticated
using (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.property_belongs_to_org(property_id, org_id)
);

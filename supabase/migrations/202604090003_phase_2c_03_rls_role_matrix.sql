create or replace function public.is_org_member(target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.org_memberships membership
        where membership.org_id = target_org_id
          and membership.user_id = auth.uid()
          and membership.deleted_at is null
    );
$$;

create or replace function public.has_org_role(target_org_id uuid, allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.org_memberships membership
        where membership.org_id = target_org_id
          and membership.user_id = auth.uid()
          and membership.role = any(allowed_roles)
          and membership.deleted_at is null
    );
$$;

create or replace function public.shares_org_with_user(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.org_memberships mine
        join public.org_memberships theirs
          on theirs.org_id = mine.org_id
        where mine.user_id = auth.uid()
          and theirs.user_id = target_user_id
          and mine.deleted_at is null
          and theirs.deleted_at is null
    );
$$;

create or replace function public.property_belongs_to_org(target_property_id uuid, target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.properties property
        where property.id = target_property_id
          and property.org_id = target_org_id
          and property.deleted_at is null
    );
$$;

create or replace function public.session_belongs_to_org(target_session_id uuid, target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.sessions session_row
        where session_row.id = target_session_id
          and session_row.org_id = target_org_id
          and session_row.deleted_at is null
    );
$$;

create or replace function public.shot_matches_observation(target_shot_id uuid, target_session_id uuid, target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select target_shot_id is null
        or exists (
            select 1
            from public.shots shot
            where shot.id = target_shot_id
              and shot.session_id = target_session_id
              and shot.org_id = target_org_id
              and shot.deleted_at is null
        );
$$;

create or replace function public.updated_by_matches_actor(target_updated_by uuid)
returns boolean
language sql
stable
as $$
    select target_updated_by is null or target_updated_by = auth.uid();
$$;

alter table public.orgs enable row level security;
alter table public.users_profile enable row level security;
alter table public.org_memberships enable row level security;
alter table public.properties enable row level security;
alter table public.sessions enable row level security;
alter table public.shots enable row level security;
alter table public.observations enable row level security;
alter table public.session_events enable row level security;

grant usage on schema public to authenticated;

revoke all on public.orgs from anon, authenticated;
revoke all on public.users_profile from anon, authenticated;
revoke all on public.org_memberships from anon, authenticated;
revoke all on public.properties from anon, authenticated;
revoke all on public.sessions from anon, authenticated;
revoke all on public.shots from anon, authenticated;
revoke all on public.observations from anon, authenticated;
revoke all on public.session_events from anon, authenticated;

grant select, update on public.orgs to authenticated;
grant select, insert, update on public.users_profile to authenticated;
grant select, insert, update on public.org_memberships to authenticated;
grant select, insert, update on public.properties to authenticated;
grant select, insert, update on public.sessions to authenticated;
grant select, insert, update on public.shots to authenticated;
grant select, insert, update on public.observations to authenticated;
grant select, insert on public.session_events to authenticated;

drop policy if exists orgs_select_member on public.orgs;
create policy orgs_select_member
on public.orgs
for select
to authenticated
using (public.is_org_member(id));

drop policy if exists orgs_update_owner_manager on public.orgs;
create policy orgs_update_owner_manager
on public.orgs
for update
to authenticated
using (public.has_org_role(id, array['owner', 'manager']))
with check (
    public.has_org_role(id, array['owner', 'manager'])
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists users_profile_select_self_or_org on public.users_profile;
create policy users_profile_select_self_or_org
on public.users_profile
for select
to authenticated
using (
    id = auth.uid()
    or public.shares_org_with_user(id)
);

drop policy if exists users_profile_insert_self on public.users_profile;
create policy users_profile_insert_self
on public.users_profile
for insert
to authenticated
with check (
    id = auth.uid()
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists users_profile_update_self on public.users_profile;
create policy users_profile_update_self
on public.users_profile
for update
to authenticated
using (id = auth.uid())
with check (
    id = auth.uid()
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists org_memberships_select_member on public.org_memberships;
create policy org_memberships_select_member
on public.org_memberships
for select
to authenticated
using (public.is_org_member(org_id));

drop policy if exists org_memberships_insert_owner on public.org_memberships;
create policy org_memberships_insert_owner
on public.org_memberships
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner'])
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists org_memberships_update_owner on public.org_memberships;
create policy org_memberships_update_owner
on public.org_memberships
for update
to authenticated
using (public.has_org_role(org_id, array['owner']))
with check (
    public.has_org_role(org_id, array['owner'])
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists properties_select_member on public.properties;
create policy properties_select_member
on public.properties
for select
to authenticated
using (public.is_org_member(org_id));

drop policy if exists properties_insert_owner_manager on public.properties;
create policy properties_insert_owner_manager
on public.properties
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager'])
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists properties_update_owner_manager on public.properties;
create policy properties_update_owner_manager
on public.properties
for update
to authenticated
using (public.has_org_role(org_id, array['owner', 'manager']))
with check (
    public.has_org_role(org_id, array['owner', 'manager'])
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists sessions_select_member on public.sessions;
create policy sessions_select_member
on public.sessions
for select
to authenticated
using (public.is_org_member(org_id));

drop policy if exists sessions_insert_owner_manager_field on public.sessions;
create policy sessions_insert_owner_manager_field
on public.sessions
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists sessions_update_owner_manager_field on public.sessions;
create policy sessions_update_owner_manager_field
on public.sessions
for update
to authenticated
using (public.has_org_role(org_id, array['owner', 'manager', 'field']))
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists shots_select_member on public.shots;
create policy shots_select_member
on public.shots
for select
to authenticated
using (public.is_org_member(org_id));

drop policy if exists shots_insert_owner_manager_field on public.shots;
create policy shots_insert_owner_manager_field
on public.shots
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists shots_update_owner_manager_field on public.shots;
create policy shots_update_owner_manager_field
on public.shots
for update
to authenticated
using (public.has_org_role(org_id, array['owner', 'manager', 'field']))
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists observations_select_member on public.observations;
create policy observations_select_member
on public.observations
for select
to authenticated
using (public.is_org_member(org_id));

drop policy if exists observations_insert_owner_manager_field on public.observations;
create policy observations_insert_owner_manager_field
on public.observations
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
    and public.shot_matches_observation(shot_id, session_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists observations_update_owner_manager_field on public.observations;
create policy observations_update_owner_manager_field
on public.observations
for update
to authenticated
using (public.has_org_role(org_id, array['owner', 'manager', 'field']))
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
    and public.shot_matches_observation(shot_id, session_id, org_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists session_events_select_member on public.session_events;
create policy session_events_select_member
on public.session_events
for select
to authenticated
using (public.is_org_member(org_id));

drop policy if exists session_events_insert_owner_manager_field on public.session_events;
create policy session_events_insert_owner_manager_field
on public.session_events
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
);

drop policy if exists session_events_update_denied on public.session_events;
create policy session_events_update_denied
on public.session_events
for update
to authenticated
using (false)
with check (false);

drop policy if exists session_events_delete_denied on public.session_events;
create policy session_events_delete_denied
on public.session_events
for delete
to authenticated
using (false);

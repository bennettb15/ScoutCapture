alter table public.org_memberships
    add column if not exists access_scope text not null default 'org';

update public.org_memberships
set access_scope = 'org'
where access_scope is null;

alter table public.org_memberships
    drop constraint if exists org_memberships_access_scope_check;

alter table public.org_memberships
    add constraint org_memberships_access_scope_check
    check (access_scope in ('org', 'property'));

create table if not exists public.property_access_grants (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    property_id uuid not null references public.properties(id),
    user_id uuid not null references public.users_profile(id),
    granted_by uuid not null references public.users_profile(id),
    created_at timestamptz not null default timezone('utc', now()),
    deleted_at timestamptz
);

create unique index if not exists idx_property_access_grants_active_unique
    on public.property_access_grants (org_id, property_id, user_id)
    where deleted_at is null;

create index if not exists idx_property_access_grants_user_active
    on public.property_access_grants (user_id, org_id)
    where deleted_at is null;

create index if not exists idx_property_access_grants_property_active
    on public.property_access_grants (property_id, user_id)
    where deleted_at is null;

create or replace function public.is_active_org_member_user(target_org_id uuid, target_user_id uuid)
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
          and membership.user_id = target_user_id
          and membership.deleted_at is null
    );
$$;

create or replace function public.user_has_org_role(target_org_id uuid, target_user_id uuid, allowed_roles text[])
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
          and membership.user_id = target_user_id
          and membership.role = any(allowed_roles)
          and membership.deleted_at is null
    );
$$;

create or replace function public.user_has_property_access(
    target_org_id uuid,
    target_property_id uuid,
    target_user_id uuid
)
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
          and membership.user_id = target_user_id
          and membership.deleted_at is null
          and (
              membership.role = 'owner'
              or membership.access_scope = 'org'
              or exists (
                  select 1
                  from public.property_access_grants grant_row
                  where grant_row.org_id = target_org_id
                    and grant_row.property_id = target_property_id
                    and grant_row.user_id = target_user_id
                    and grant_row.deleted_at is null
              )
          )
    )
    and exists (
        select 1
        from public.properties property
        where property.id = target_property_id
          and property.org_id = target_org_id
          and property.deleted_at is null
    );
$$;

create or replace function public.has_property_access(target_org_id uuid, target_property_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.user_has_property_access(target_org_id, target_property_id, auth.uid());
$$;

create or replace function public.has_session_access(target_org_id uuid, target_session_id uuid)
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
          and public.has_property_access(target_org_id, session_row.property_id)
    );
$$;

create or replace function public.has_shot_access(target_org_id uuid, target_shot_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.shots shot
        join public.sessions session_row
          on session_row.id = shot.session_id
        where shot.id = target_shot_id
          and shot.org_id = target_org_id
          and shot.deleted_at is null
          and session_row.deleted_at is null
          and public.has_property_access(target_org_id, session_row.property_id)
    );
$$;

create or replace function public.has_observation_access(target_org_id uuid, target_observation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.observations observation_row
        join public.sessions session_row
          on session_row.id = observation_row.session_id
        where observation_row.id = target_observation_id
          and observation_row.org_id = target_org_id
          and observation_row.deleted_at is null
          and session_row.deleted_at is null
          and public.has_property_access(target_org_id, session_row.property_id)
    );
$$;

alter table public.property_access_grants enable row level security;

revoke all on public.property_access_grants from anon, authenticated;
grant select, insert, update on public.property_access_grants to authenticated;

drop policy if exists property_access_grants_select_owner_or_self on public.property_access_grants;
create policy property_access_grants_select_owner_or_self
on public.property_access_grants
for select
to authenticated
using (
    (
        user_id = auth.uid()
        and public.is_active_org_member_user(org_id, auth.uid())
    )
    or public.has_org_role(org_id, array['owner'])
);

drop policy if exists property_access_grants_insert_owner on public.property_access_grants;
create policy property_access_grants_insert_owner
on public.property_access_grants
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.is_active_org_member_user(org_id, user_id)
    and granted_by = auth.uid()
);

drop policy if exists property_access_grants_update_owner on public.property_access_grants;
create policy property_access_grants_update_owner
on public.property_access_grants
for update
to authenticated
using (public.has_org_role(org_id, array['owner']))
with check (
    public.has_org_role(org_id, array['owner'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.is_active_org_member_user(org_id, user_id)
);

drop policy if exists properties_select_member on public.properties;
create policy properties_select_member
on public.properties
for select
to authenticated
using (public.has_property_access(org_id, id));

drop policy if exists properties_update_owner_manager on public.properties;
create policy properties_update_owner_manager
on public.properties
for update
to authenticated
using (
    public.has_org_role(org_id, array['owner', 'manager'])
    and public.has_property_access(org_id, id)
)
with check (
    public.has_org_role(org_id, array['owner', 'manager'])
    and public.has_property_access(org_id, id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists sessions_select_member on public.sessions;
create policy sessions_select_member
on public.sessions
for select
to authenticated
using (public.has_session_access(org_id, id));

drop policy if exists sessions_insert_owner_manager_field on public.sessions;
create policy sessions_insert_owner_manager_field
on public.sessions
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.has_property_access(org_id, property_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists sessions_update_owner_manager_field on public.sessions;
create policy sessions_update_owner_manager_field
on public.sessions
for update
to authenticated
using (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.has_session_access(org_id, id)
)
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.has_property_access(org_id, property_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists shots_select_member on public.shots;
create policy shots_select_member
on public.shots
for select
to authenticated
using (public.has_shot_access(org_id, id));

drop policy if exists shots_insert_owner_manager_field on public.shots;
create policy shots_insert_owner_manager_field
on public.shots
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
    and public.has_session_access(org_id, session_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists shots_update_owner_manager_field on public.shots;
create policy shots_update_owner_manager_field
on public.shots
for update
to authenticated
using (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.has_shot_access(org_id, id)
)
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
    and public.has_session_access(org_id, session_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists observations_select_member on public.observations;
create policy observations_select_member
on public.observations
for select
to authenticated
using (public.has_observation_access(org_id, id));

drop policy if exists observations_insert_owner_manager_field on public.observations;
create policy observations_insert_owner_manager_field
on public.observations
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
    and public.has_session_access(org_id, session_id)
    and public.shot_matches_observation(shot_id, session_id, org_id)
    and (
        shot_id is null
        or public.has_shot_access(org_id, shot_id)
    )
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists observations_update_owner_manager_field on public.observations;
create policy observations_update_owner_manager_field
on public.observations
for update
to authenticated
using (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.has_observation_access(org_id, id)
)
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
    and public.has_session_access(org_id, session_id)
    and public.shot_matches_observation(shot_id, session_id, org_id)
    and (
        shot_id is null
        or public.has_shot_access(org_id, shot_id)
    )
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists session_events_select_member on public.session_events;
create policy session_events_select_member
on public.session_events
for select
to authenticated
using (public.has_session_access(org_id, session_id));

drop policy if exists session_events_insert_owner_manager_field on public.session_events;
create policy session_events_insert_owner_manager_field
on public.session_events
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_belongs_to_org(session_id, org_id)
    and public.has_session_access(org_id, session_id)
);

drop policy if exists property_session_occupancy_select_member on public.property_session_occupancy;
create policy property_session_occupancy_select_member
on public.property_session_occupancy
for select
to authenticated
using (public.has_property_access(org_id, property_id));

drop policy if exists property_session_occupancy_insert_owner_manager_field on public.property_session_occupancy;
create policy property_session_occupancy_insert_owner_manager_field
on public.property_session_occupancy
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.has_property_access(org_id, property_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists property_session_occupancy_update_owner_manager_field on public.property_session_occupancy;
create policy property_session_occupancy_update_owner_manager_field
on public.property_session_occupancy
for update
to authenticated
using (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.has_property_access(org_id, property_id)
)
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.property_belongs_to_org(property_id, org_id)
    and public.has_property_access(org_id, property_id)
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists property_session_occupancy_delete_owner_manager_field on public.property_session_occupancy;
create policy property_session_occupancy_delete_owner_manager_field
on public.property_session_occupancy
for delete
to authenticated
using (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.has_property_access(org_id, property_id)
    and public.property_belongs_to_org(property_id, org_id)
);

create or replace function public.accept_org_invitation(
    target_invitation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    actor_id uuid := public.ensure_current_user_profile();
    actor_email text := lower(trim(
        coalesce(
            nullif(auth.email(), ''),
            nullif(auth.jwt() ->> 'email', ''),
            ''
        )
    ));
    invitation_row public.org_invitations%rowtype;
begin
    if actor_id is null then
        raise exception 'Authenticated user required';
    end if;

    if actor_email = '' then
        raise exception 'Authenticated email required';
    end if;

    select *
    into invitation_row
    from public.org_invitations
    where id = target_invitation_id
      and accepted_at is null
      and revoked_at is null
      and lower(invitee_email) = actor_email
    for update;

    if not found then
        raise exception 'Pending invitation not found for the authenticated user';
    end if;

    insert into public.org_memberships (
        org_id,
        user_id,
        role,
        access_scope,
        updated_by,
        deleted_at
    )
    values (
        invitation_row.org_id,
        actor_id,
        invitation_row.role,
        'org',
        actor_id,
        null
    )
    on conflict (org_id, user_id) do update
    set role = excluded.role,
        access_scope = 'org',
        updated_by = excluded.updated_by,
        deleted_at = null;

    update public.org_invitations
    set accepted_at = timezone('utc', now())
    where id = invitation_row.id;

    return invitation_row.org_id;
end;
$$;

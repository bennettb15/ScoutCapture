alter table public.observations
    add column if not exists property_id uuid references public.properties(id),
    add column if not exists first_seen_session_id uuid references public.sessions(id),
    add column if not exists last_update_session_id uuid references public.sessions(id),
    add column if not exists resolved_session_id uuid references public.sessions(id),
    add column if not exists first_seen_at timestamptz,
    add column if not exists last_seen_at timestamptz,
    add column if not exists resolved_at timestamptz,
    add column if not exists priority text,
    add column if not exists trade text;

update public.observations observation_row
set property_id = session_row.property_id,
    first_seen_session_id = coalesce(observation_row.first_seen_session_id, observation_row.session_id),
    last_update_session_id = coalesce(observation_row.last_update_session_id, observation_row.session_id),
    first_seen_at = coalesce(observation_row.first_seen_at, observation_row.created_at),
    last_seen_at = coalesce(observation_row.last_seen_at, observation_row.updated_at),
    resolved_at = case
        when lower(coalesce(observation_row.status, '')) = 'resolved'
            then coalesce(observation_row.resolved_at, observation_row.updated_at)
        else observation_row.resolved_at
    end,
    resolved_session_id = case
        when lower(coalesce(observation_row.status, '')) = 'resolved'
            then coalesce(observation_row.resolved_session_id, observation_row.session_id)
        else observation_row.resolved_session_id
    end
from public.sessions session_row
where session_row.id = observation_row.session_id
  and observation_row.property_id is null;

do $$
begin
    if exists (
        select 1
        from public.observations observation_row
        where observation_row.property_id is null
    ) then
        raise exception 'Phase 2C-28 observation lineage migration blocked: observations.property_id could not be derived from legacy session_id.';
    end if;
end;
$$;

create or replace function public.hydrate_observation_lineage_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    session_property_id uuid;
begin
    select session_row.property_id
      into session_property_id
      from public.sessions session_row
     where session_row.id = new.session_id
       and session_row.org_id = new.org_id;

    if new.property_id is null then
        new.property_id := session_property_id;
    end if;

    if new.first_seen_session_id is null then
        new.first_seen_session_id := new.session_id;
    end if;

    if new.last_update_session_id is null then
        new.last_update_session_id := new.session_id;
    end if;

    if new.first_seen_at is null then
        new.first_seen_at := coalesce(new.created_at, timezone('utc', now()));
    end if;

    if new.last_seen_at is null then
        new.last_seen_at := coalesce(new.updated_at, new.created_at, timezone('utc', now()));
    end if;

    if lower(coalesce(new.status, '')) = 'resolved' then
        if new.resolved_session_id is null then
            new.resolved_session_id := new.session_id;
        end if;
        if new.resolved_at is null then
            new.resolved_at := coalesce(new.updated_at, new.created_at, timezone('utc', now()));
        end if;
    end if;

    return new;
end;
$$;

drop trigger if exists hydrate_observation_lineage_defaults on public.observations;
create trigger hydrate_observation_lineage_defaults
    before insert or update on public.observations
    for each row
    execute function public.hydrate_observation_lineage_defaults();

alter table public.observations
    alter column property_id set not null;

create table if not exists public.observation_updates (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    property_id uuid not null references public.properties(id),
    observation_id uuid not null references public.observations(id),
    session_id uuid not null references public.sessions(id),
    shot_id uuid references public.shots(id),
    update_type text not null,
    status text not null,
    message text,
    note text,
    priority text,
    trade text,
    captured_at timestamptz,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid references public.users_profile(id),
    revision bigint not null default 1,
    deleted_at timestamptz
);

alter table public.observation_updates
    drop constraint if exists observation_updates_update_type_check;
alter table public.observation_updates
    add constraint observation_updates_update_type_check
    check (update_type in ('created', 'captured', 'carried_forward', 'resolved', 'message_updated'));

alter table public.observation_updates
    drop constraint if exists observation_updates_status_check;
alter table public.observation_updates
    add constraint observation_updates_status_check
    check (status in ('active', 'resolved'));

drop trigger if exists set_observation_updates_updated_at on public.observation_updates;
create trigger set_observation_updates_updated_at
    before update on public.observation_updates
    for each row
    execute function public.set_updated_at();

create index if not exists idx_observations_property_status_active
    on public.observations (property_id, status, updated_at desc)
    where deleted_at is null;

create index if not exists idx_observations_org_property_active
    on public.observations (org_id, property_id, updated_at desc)
    where deleted_at is null;

create index if not exists idx_observations_first_seen_session_active
    on public.observations (first_seen_session_id, updated_at desc)
    where first_seen_session_id is not null and deleted_at is null;

create index if not exists idx_observation_updates_session_active
    on public.observation_updates (session_id, updated_at desc)
    where deleted_at is null;

create index if not exists idx_observation_updates_observation_created
    on public.observation_updates (observation_id, created_at desc)
    where deleted_at is null;

create index if not exists idx_observation_updates_property_session_active
    on public.observation_updates (property_id, session_id, updated_at desc)
    where deleted_at is null;

create unique index if not exists idx_observation_updates_shot_event_active
    on public.observation_updates (observation_id, session_id, shot_id, update_type)
    where shot_id is not null and deleted_at is null;

create unique index if not exists idx_observation_updates_session_event_active
    on public.observation_updates (observation_id, session_id, update_type)
    where shot_id is null and deleted_at is null;

create or replace function public.observation_lineage_scope_valid(
    target_org_id uuid,
    target_property_id uuid,
    target_session_id uuid,
    target_first_seen_session_id uuid,
    target_last_update_session_id uuid,
    target_resolved_session_id uuid,
    target_shot_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.property_belongs_to_org(target_property_id, target_org_id)
        and public.session_matches_property(target_session_id, target_property_id, target_org_id)
        and public.session_matches_property(target_first_seen_session_id, target_property_id, target_org_id)
        and public.session_matches_property(target_last_update_session_id, target_property_id, target_org_id)
        and public.session_matches_property(target_resolved_session_id, target_property_id, target_org_id)
        and public.shot_matches_observation(target_shot_id, target_session_id, target_org_id);
$$;

create or replace function public.observation_update_scope_valid(
    target_org_id uuid,
    target_property_id uuid,
    target_observation_id uuid,
    target_session_id uuid,
    target_shot_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.property_belongs_to_org(target_property_id, target_org_id)
        and public.session_matches_property(target_session_id, target_property_id, target_org_id)
        and public.shot_matches_observation(target_shot_id, target_session_id, target_org_id)
        and exists (
            select 1
            from public.observations observation_row
            where observation_row.id = target_observation_id
              and observation_row.org_id = target_org_id
              and observation_row.property_id = target_property_id
        );
$$;

do $$
begin
    if exists (
        select 1
        from public.observations observation_row
        where not public.observation_lineage_scope_valid(
            observation_row.org_id,
            observation_row.property_id,
            observation_row.session_id,
            observation_row.first_seen_session_id,
            observation_row.last_update_session_id,
            observation_row.resolved_session_id,
            observation_row.shot_id
        )
    ) then
        raise exception 'Phase 2C-28 observation lineage migration blocked: legacy observation parent scope is invalid.';
    end if;
end;
$$;

do $$
begin
    if exists (
        select 1
        from public.observations observation_row
        where not public.observation_update_scope_valid(
            observation_row.org_id,
            observation_row.property_id,
            observation_row.id,
            observation_row.session_id,
            observation_row.shot_id
        )
    ) then
        raise exception 'Phase 2C-28 observation lineage migration blocked: legacy observation would produce an invalid observation_update parent scope.';
    end if;
end;
$$;

alter table public.observations
    drop constraint if exists observations_lineage_scope_check;
alter table public.observations
    add constraint observations_lineage_scope_check
    check (
        public.observation_lineage_scope_valid(
            org_id,
            property_id,
            session_id,
            first_seen_session_id,
            last_update_session_id,
            resolved_session_id,
            shot_id
        )
    ) not valid;

alter table public.observation_updates
    drop constraint if exists observation_updates_scope_check;
alter table public.observation_updates
    add constraint observation_updates_scope_check
    check (
        public.observation_update_scope_valid(
            org_id,
            property_id,
            observation_id,
            session_id,
            shot_id
        )
    ) not valid;

insert into public.observation_updates (
    org_id,
    property_id,
    observation_id,
    session_id,
    shot_id,
    update_type,
    status,
    message,
    note,
    priority,
    trade,
    captured_at,
    created_at,
    updated_at,
    updated_by,
    revision,
    deleted_at
)
select
    observation_row.org_id,
    observation_row.property_id,
    observation_row.id,
    observation_row.session_id,
    observation_row.shot_id,
    case
        when lower(coalesce(observation_row.status, '')) = 'resolved' then 'resolved'
        else 'captured'
    end,
    case
        when lower(coalesce(observation_row.status, '')) = 'resolved' then 'resolved'
        else 'active'
    end,
    observation_row.title,
    observation_row.detail,
    observation_row.priority,
    observation_row.trade,
    coalesce(observation_row.last_seen_at, observation_row.updated_at, observation_row.created_at),
    observation_row.created_at,
    observation_row.updated_at,
    observation_row.updated_by,
    observation_row.revision,
    observation_row.deleted_at
from public.observations observation_row
where not exists (
    select 1
    from public.observation_updates update_row
    where update_row.observation_id = observation_row.id
      and update_row.session_id = observation_row.session_id
      and update_row.update_type = case
          when lower(coalesce(observation_row.status, '')) = 'resolved' then 'resolved'
          else 'captured'
      end
      and (
          update_row.shot_id is not distinct from observation_row.shot_id
      )
);

alter table public.observation_updates
    validate constraint observation_updates_scope_check;

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
          and session_row.org_id = target_org_id
          and session_row.property_id = observation_row.property_id
          and session_row.deleted_at is null
          and public.has_property_access(target_org_id, session_row.property_id)
    );
$$;

create or replace function public.has_observation_update_access(
    target_org_id uuid,
    target_property_id uuid,
    target_session_id uuid,
    target_observation_id uuid,
    target_shot_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.observation_update_scope_valid(
            target_org_id,
            target_property_id,
            target_observation_id,
            target_session_id,
            target_shot_id
        )
        and public.has_property_access(target_org_id, target_property_id)
        and public.has_session_access(target_org_id, target_session_id)
        and public.has_observation_access(target_org_id, target_observation_id);
$$;

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
    and public.observation_lineage_scope_valid(
        org_id,
        property_id,
        session_id,
        first_seen_session_id,
        last_update_session_id,
        resolved_session_id,
        shot_id
    )
    and public.has_property_access(org_id, property_id)
    and public.has_session_access(org_id, session_id)
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
    and public.observation_lineage_scope_valid(
        org_id,
        property_id,
        session_id,
        first_seen_session_id,
        last_update_session_id,
        resolved_session_id,
        shot_id
    )
    and public.has_property_access(org_id, property_id)
    and public.has_session_access(org_id, session_id)
    and (
        shot_id is null
        or public.has_shot_access(org_id, shot_id)
    )
    and public.updated_by_matches_actor(updated_by)
);

alter table public.observation_updates enable row level security;

revoke all on public.observation_updates from anon, authenticated;
grant select, insert, update on public.observation_updates to authenticated;
grant select, insert, update, delete on public.observation_updates to service_role;

drop policy if exists observation_updates_select_member on public.observation_updates;
create policy observation_updates_select_member
on public.observation_updates
for select
to authenticated
using (
    public.has_observation_update_access(org_id, property_id, session_id, observation_id, shot_id)
);

drop policy if exists observation_updates_insert_owner_manager_field on public.observation_updates;
create policy observation_updates_insert_owner_manager_field
on public.observation_updates
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.observation_update_scope_valid(org_id, property_id, observation_id, session_id, shot_id)
    and public.has_property_access(org_id, property_id)
    and public.has_session_access(org_id, session_id)
    and public.has_observation_access(org_id, observation_id)
    and (
        shot_id is null
        or public.has_shot_access(org_id, shot_id)
    )
    and public.updated_by_matches_actor(updated_by)
);

drop policy if exists observation_updates_update_owner_manager_field on public.observation_updates;
create policy observation_updates_update_owner_manager_field
on public.observation_updates
for update
to authenticated
using (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.has_observation_update_access(org_id, property_id, session_id, observation_id, shot_id)
)
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.observation_update_scope_valid(org_id, property_id, observation_id, session_id, shot_id)
    and public.has_property_access(org_id, property_id)
    and public.has_session_access(org_id, session_id)
    and public.has_observation_access(org_id, observation_id)
    and (
        shot_id is null
        or public.has_shot_access(org_id, shot_id)
    )
    and public.updated_by_matches_actor(updated_by)
);

comment on column public.observations.property_id is
'Persistent property scope for flagged observations. Phase 2C-28 keeps observations.session_id intact as legacy/origin scope while session-specific history moves to observation_updates.';

comment on table public.observation_updates is
'Session-scoped flagged observation history/evidence rows. A persistent observation can have updates across multiple sessions without moving or duplicating observations.id.';

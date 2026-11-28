-- Source: scout-site@ef46714:supabase/migrations/202608260001_punchlist_activity.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Scout Website punchlist operational activity.
-- Append-only notes now; status/priority/trade activity types are reserved for
-- later editable workflow without touching shots or sealed report snapshots.

create table if not exists public.punchlist_activity (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    property_id uuid not null references public.properties(id),
    observation_id uuid not null references public.observations(id),
    shot_id uuid references public.shots(id),
    activity_type text not null,
    from_value text,
    to_value text,
    note text,
    created_by uuid not null references public.users_profile(id),
    created_at timestamptz not null default timezone('utc', now()),
    deleted_at timestamptz
);

alter table public.punchlist_activity
    drop constraint if exists punchlist_activity_type_check;
alter table public.punchlist_activity
    add constraint punchlist_activity_type_check
    check (activity_type in ('note_added', 'status_changed', 'priority_changed', 'trade_changed'));

alter table public.punchlist_activity
    drop constraint if exists punchlist_activity_note_check;
alter table public.punchlist_activity
    add constraint punchlist_activity_note_check
    check (
        activity_type <> 'note_added'
        or nullif(trim(coalesce(note, '')), '') is not null
    );

create or replace function public.punchlist_activity_scope_valid(
    target_org_id uuid,
    target_property_id uuid,
    target_observation_id uuid,
    target_shot_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.property_belongs_to_org(target_property_id, target_org_id)
        and exists (
            select 1
            from public.observations observation_row
            where observation_row.id = target_observation_id
              and observation_row.org_id = target_org_id
              and observation_row.property_id = target_property_id
              and observation_row.deleted_at is null
              and (
                  target_shot_id is null
                  or observation_row.shot_id is not distinct from target_shot_id
              )
        );
$$;

alter table public.punchlist_activity
    drop constraint if exists punchlist_activity_scope_check;
alter table public.punchlist_activity
    add constraint punchlist_activity_scope_check
    check (
        public.punchlist_activity_scope_valid(
            org_id,
            property_id,
            observation_id,
            shot_id
        )
    ) not valid;

create index if not exists idx_punchlist_activity_observation_created
    on public.punchlist_activity (observation_id, created_at desc)
    where deleted_at is null;

create index if not exists idx_punchlist_activity_org_property_created
    on public.punchlist_activity (org_id, property_id, created_at desc)
    where deleted_at is null;

alter table public.punchlist_activity enable row level security;

revoke all on public.punchlist_activity from anon, authenticated;
grant select, insert on public.punchlist_activity to authenticated;
grant select, insert, update, delete on public.punchlist_activity to service_role;

drop policy if exists punchlist_activity_select_member on public.punchlist_activity;
create policy punchlist_activity_select_member
on public.punchlist_activity
for select
to authenticated
using (
    public.has_observation_access(org_id, observation_id)
);

drop policy if exists punchlist_activity_insert_owner_manager_field on public.punchlist_activity;
create policy punchlist_activity_insert_owner_manager_field
on public.punchlist_activity
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.has_observation_access(org_id, observation_id)
    and public.punchlist_activity_scope_valid(org_id, property_id, observation_id, shot_id)
    and public.updated_by_matches_actor(created_by)
);

drop policy if exists punchlist_activity_update_denied on public.punchlist_activity;
create policy punchlist_activity_update_denied
on public.punchlist_activity
for update
to authenticated
using (false)
with check (false);

drop policy if exists punchlist_activity_delete_denied on public.punchlist_activity;
create policy punchlist_activity_delete_denied
on public.punchlist_activity
for delete
to authenticated
using (false);

alter table public.punchlist_activity
    validate constraint punchlist_activity_scope_check;

comment on table public.punchlist_activity is
'Append-only operational punchlist activity for the Scout Website. Notes and future workflow edits live here without mutating shots or sealed report snapshot payloads.';

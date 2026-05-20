alter table public.session_events
    alter column session_id drop not null;

alter table public.session_events
    add column if not exists property_id uuid references public.properties(id),
    add column if not exists actor_user_id uuid references public.users_profile(id);

alter table public.session_events
    alter column actor_user_id set default auth.uid();

create index if not exists idx_session_events_property_created
    on public.session_events (property_id, created_at desc);

create index if not exists idx_session_events_actor_created
    on public.session_events (actor_user_id, created_at desc);

create or replace function public.session_matches_property(
    target_session_id uuid,
    target_property_id uuid,
    target_org_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select target_session_id is null
        or target_property_id is null
        or exists (
            select 1
            from public.sessions session_row
            where session_row.id = target_session_id
              and session_row.org_id = target_org_id
              and session_row.property_id = target_property_id
              and session_row.deleted_at is null
        );
$$;

create or replace function public.session_event_scope_valid(
    target_org_id uuid,
    target_property_id uuid,
    target_session_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select (
        target_property_id is null
        or public.property_belongs_to_org(target_property_id, target_org_id)
    )
    and (
        target_session_id is null
        or public.session_belongs_to_org(target_session_id, target_org_id)
    )
    and public.session_matches_property(target_session_id, target_property_id, target_org_id);
$$;

create or replace function public.has_session_event_access(
    target_org_id uuid,
    target_property_id uuid,
    target_session_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.session_event_scope_valid(target_org_id, target_property_id, target_session_id)
        and case
            when target_session_id is not null then
                public.has_session_access(target_org_id, target_session_id)
            when target_property_id is not null then
                public.has_property_access(target_org_id, target_property_id)
            else
                public.is_org_member(target_org_id)
        end;
$$;

create or replace function public.can_insert_session_event(
    target_org_id uuid,
    target_property_id uuid,
    target_session_id uuid,
    target_actor_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.session_event_scope_valid(target_org_id, target_property_id, target_session_id)
        and coalesce(target_actor_user_id, auth.uid()) = auth.uid()
        and case
            when target_session_id is not null then
                public.has_org_role(target_org_id, array['owner', 'manager', 'field'])
                and public.has_session_access(target_org_id, target_session_id)
            when target_property_id is not null then
                public.is_org_member(target_org_id)
                and public.has_property_access(target_org_id, target_property_id)
            else
                public.is_org_member(target_org_id)
        end;
$$;

alter table public.session_events
    drop constraint if exists session_events_scope_consistency_check;

alter table public.session_events
    add constraint session_events_scope_consistency_check
    check (public.session_event_scope_valid(org_id, property_id, session_id));

drop policy if exists session_events_select_member on public.session_events;
create policy session_events_select_member
on public.session_events
for select
to authenticated
using (public.has_session_event_access(org_id, property_id, session_id));

drop policy if exists session_events_insert_owner_manager_field on public.session_events;
create policy session_events_insert_owner_manager_field
on public.session_events
for insert
to authenticated
with check (
    public.can_insert_session_event(org_id, property_id, session_id, actor_user_id)
);

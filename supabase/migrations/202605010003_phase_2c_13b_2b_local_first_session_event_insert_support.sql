create or replace function public.session_event_insert_scope_valid(
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
    and case
        when target_session_id is null then
            true
        when public.session_belongs_to_org(target_session_id, target_org_id) then
            public.session_matches_property(target_session_id, target_property_id, target_org_id)
        else
            target_property_id is not null
            and not exists (
                select 1
                from public.sessions session_row
                where session_row.id = target_session_id
                  and session_row.deleted_at is null
            )
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
    select public.session_event_insert_scope_valid(target_org_id, target_property_id, target_session_id)
        and coalesce(target_actor_user_id, auth.uid()) = auth.uid()
        and case
            when target_session_id is not null then
                target_property_id is not null
                and public.has_property_access(target_org_id, target_property_id)
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
    check (public.session_event_insert_scope_valid(org_id, property_id, session_id));

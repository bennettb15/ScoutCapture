-- Property soft-delete succeeds before the app emits its property.deleted event.
-- Keep historical property links valid for event scope checks, then allow only
-- owner/manager property.deleted events while the property is soft-deleted.
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
        or exists (
            select 1
            from public.properties property
            where property.id = target_property_id
              and property.org_id = target_org_id
        )
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

create or replace function public.owner_can_access_soft_deleted_property(
    target_org_id uuid,
    target_property_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.has_org_role(target_org_id, array['owner', 'manager'])
        and exists (
            select 1
            from public.properties property
            where property.id = target_property_id
              and property.org_id = target_org_id
              and property.deleted_at is not null
        );
$$;

revoke all on function public.owner_can_access_soft_deleted_property(uuid, uuid) from public, anon;
grant execute on function public.owner_can_access_soft_deleted_property(uuid, uuid) to authenticated;

drop policy if exists session_events_insert_owner_manager_field on public.session_events;
create policy session_events_insert_owner_manager_field
on public.session_events
for insert
to authenticated
with check (
    public.can_insert_session_event(org_id, property_id, session_id, actor_user_id)
    or (
        event_type = 'property.deleted'
        and session_id is null
        and coalesce(actor_user_id, auth.uid()) = auth.uid()
        and public.owner_can_access_soft_deleted_property(org_id, property_id)
    )
);

drop policy if exists session_events_select_member on public.session_events;
create policy session_events_select_member
on public.session_events
for select
to authenticated
using (
    public.has_session_event_access(org_id, property_id, session_id)
    or (
        event_type = 'property.deleted'
        and session_id is null
        and public.owner_can_access_soft_deleted_property(org_id, property_id)
    )
);

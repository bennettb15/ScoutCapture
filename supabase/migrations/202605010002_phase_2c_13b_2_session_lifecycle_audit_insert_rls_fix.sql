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
                public.has_session_access(target_org_id, target_session_id)
            when target_property_id is not null then
                public.is_org_member(target_org_id)
                and public.has_property_access(target_org_id, target_property_id)
            else
                public.is_org_member(target_org_id)
        end;
$$;

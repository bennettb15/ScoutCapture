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
    select case
        when target_session_id is not null
             and public.session_belongs_to_org(target_session_id, target_org_id) then
            public.session_matches_property(target_session_id, target_property_id, target_org_id)
            and public.has_session_access(target_org_id, target_session_id)
        when target_session_id is not null then
            public.session_event_insert_scope_valid(target_org_id, target_property_id, target_session_id)
            and target_property_id is not null
            and public.has_property_access(target_org_id, target_property_id)
        when target_property_id is not null then
            public.session_event_scope_valid(target_org_id, target_property_id, target_session_id)
            and public.has_property_access(target_org_id, target_property_id)
        else
            public.session_event_scope_valid(target_org_id, target_property_id, target_session_id)
            and public.is_org_member(target_org_id)
    end;
$$;

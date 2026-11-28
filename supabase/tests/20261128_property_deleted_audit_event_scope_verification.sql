begin;

insert into auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at,
    confirmation_token, email_change, email_change_token_new, recovery_token,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
    ('28000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'audit-owner-280001@example.test', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('28000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'audit-viewer-280001@example.test', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()));

insert into public.users_profile (id, email, updated_by)
values
    ('28000000-0000-0000-0000-000000000001', 'audit-owner-280001@example.test', '28000000-0000-0000-0000-000000000001'),
    ('28000000-0000-0000-0000-000000000002', 'audit-viewer-280001@example.test', '28000000-0000-0000-0000-000000000002')
on conflict (id) do nothing;

insert into public.orgs (id, name, slug, updated_by)
values ('28100000-0000-0000-0000-000000000001', 'Deleted Audit Test Org', 'deleted-audit-test-280001', '28000000-0000-0000-0000-000000000001');

insert into public.org_memberships (org_id, user_id, role, access_scope, updated_by)
values
    ('28100000-0000-0000-0000-000000000001', '28000000-0000-0000-0000-000000000001', 'owner', 'org', '28000000-0000-0000-0000-000000000001'),
    ('28100000-0000-0000-0000-000000000001', '28000000-0000-0000-0000-000000000002', 'viewer', 'org', '28000000-0000-0000-0000-000000000001');

insert into public.properties (id, org_id, name, updated_by, deleted_at)
values ('28200000-0000-0000-0000-000000000001', '28100000-0000-0000-0000-000000000001', 'Deleted Audit Test Property', '28000000-0000-0000-0000-000000000001', timezone('utc', now()));

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '28000000-0000-0000-0000-000000000001', true);

insert into public.session_events (id, org_id, property_id, event_type, payload)
values ('28300000-0000-0000-0000-000000000001', '28100000-0000-0000-0000-000000000001', '28200000-0000-0000-0000-000000000001', 'property.deleted', '{}'::jsonb);

do $$
begin
    if (select count(*) from public.session_events where id = '28300000-0000-0000-0000-000000000001') <> 1 then
        raise exception 'Owner should see property.deleted while the property is soft-deleted';
    end if;
end;
$$;

do $$
declare
    inserted boolean := false;
begin
    begin
        insert into public.session_events (id, org_id, property_id, event_type, payload)
        values ('28300000-0000-0000-0000-000000000002', '28100000-0000-0000-0000-000000000001', '28200000-0000-0000-0000-000000000001', 'property.archived', '{}'::jsonb);
        inserted := true;
    exception when others then
        null;
    end;
    if inserted then
        raise exception 'Other events must remain blocked for soft-deleted properties';
    end if;
end;
$$;

select set_config('request.jwt.claim.sub', '28000000-0000-0000-0000-000000000002', true);

do $$
declare
    inserted boolean := false;
begin
    begin
        insert into public.session_events (id, org_id, property_id, event_type, payload)
        values ('28300000-0000-0000-0000-000000000003', '28100000-0000-0000-0000-000000000001', '28200000-0000-0000-0000-000000000001', 'property.deleted', '{}'::jsonb);
        inserted := true;
    exception when others then
        null;
    end;
    if inserted then
        raise exception 'Viewer must not create property.deleted audit events';
    end if;
    if (select count(*) from public.session_events where id = '28300000-0000-0000-0000-000000000001') <> 0 then
        raise exception 'Viewer must not see deleted-property audit events';
    end if;
end;
$$;

rollback;

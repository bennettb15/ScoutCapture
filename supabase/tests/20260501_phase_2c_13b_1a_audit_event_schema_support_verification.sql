begin;

create or replace function public.test_assert(condition boolean, message text)
returns void
language plpgsql
as $$
begin
    if not condition then
        raise exception '%', message;
    end if;
end;
$$;

create or replace function public.test_expect_exception(statement_text text, message text)
returns void
language plpgsql
as $$
begin
    execute statement_text;
    raise exception 'Expected exception: %', message;
exception
    when others then
        null;
end;
$$;

insert into auth.users (
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    confirmation_token,
    email_change,
    email_change_token_new,
    recovery_token,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
)
values
    ('03000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-13b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'org-viewer-13b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'property-member-13b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'no-grant-13b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000005', 'authenticated', 'authenticated', 'revoked-member-13b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000006', 'authenticated', 'authenticated', 'field-13b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('03000000-0000-0000-0000-000000000001', 'owner-13b@example.com', 'Owner 13B', '03000000-0000-0000-0000-000000000001'),
    ('03000000-0000-0000-0000-000000000002', 'org-viewer-13b@example.com', 'Org Viewer 13B', '03000000-0000-0000-0000-000000000002'),
    ('03000000-0000-0000-0000-000000000003', 'property-member-13b@example.com', 'Property Member 13B', '03000000-0000-0000-0000-000000000003'),
    ('03000000-0000-0000-0000-000000000004', 'no-grant-13b@example.com', 'No Grant 13B', '03000000-0000-0000-0000-000000000004'),
    ('03000000-0000-0000-0000-000000000005', 'revoked-member-13b@example.com', 'Revoked Member 13B', '03000000-0000-0000-0000-000000000005'),
    ('03000000-0000-0000-0000-000000000006', 'field-13b@example.com', 'Field 13B', '03000000-0000-0000-0000-000000000006')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by)
values
    ('31000000-0000-0000-0000-000000000001', 'Audit Event Org A', 'audit-event-org-a', '03000000-0000-0000-0000-000000000001'),
    ('31000000-0000-0000-0000-000000000002', 'Audit Event Org B', 'audit-event-org-b', '03000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('32000000-0000-0000-0000-000000000001', '31000000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000001', 'owner', 'org', '03000000-0000-0000-0000-000000000001', null),
    ('32000000-0000-0000-0000-000000000002', '31000000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000002', 'viewer', 'org', '03000000-0000-0000-0000-000000000001', null),
    ('32000000-0000-0000-0000-000000000003', '31000000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000003', 'viewer', 'property', '03000000-0000-0000-0000-000000000001', null),
    ('32000000-0000-0000-0000-000000000004', '31000000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000004', 'viewer', 'property', '03000000-0000-0000-0000-000000000001', null),
    ('32000000-0000-0000-0000-000000000005', '31000000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000005', 'viewer', 'org', '03000000-0000-0000-0000-000000000001', timezone('utc', now())),
    ('32000000-0000-0000-0000-000000000006', '31000000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000006', 'field', 'org', '03000000-0000-0000-0000-000000000001', null),
    ('32000000-0000-0000-0000-000000000007', '31000000-0000-0000-0000-000000000002', '03000000-0000-0000-0000-000000000001', 'owner', 'org', '03000000-0000-0000-0000-000000000001', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by)
values
    ('33000000-0000-0000-0000-000000000001', '31000000-0000-0000-0000-000000000001', 'Property Alpha 13B', '03000000-0000-0000-0000-000000000001'),
    ('33000000-0000-0000-0000-000000000002', '31000000-0000-0000-0000-000000000001', 'Property Beta 13B', '03000000-0000-0000-0000-000000000001'),
    ('33000000-0000-0000-0000-000000000003', '31000000-0000-0000-0000-000000000002', 'Property Gamma 13B', '03000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.sessions (id, org_id, property_id, title, status, updated_by, deleted_at)
values
    ('34000000-0000-0000-0000-000000000001', '31000000-0000-0000-0000-000000000001', '33000000-0000-0000-0000-000000000001', 'Alpha Session 13B', 'draft', '03000000-0000-0000-0000-000000000001', null),
    ('34000000-0000-0000-0000-000000000002', '31000000-0000-0000-0000-000000000001', '33000000-0000-0000-0000-000000000002', 'Beta Session 13B', 'draft', '03000000-0000-0000-0000-000000000001', null),
    ('34000000-0000-0000-0000-000000000003', '31000000-0000-0000-0000-000000000002', '33000000-0000-0000-0000-000000000003', 'Gamma Session 13B', 'draft', '03000000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set title = excluded.title,
    status = excluded.status,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.property_access_grants (id, org_id, property_id, user_id, granted_by, deleted_at)
values
    ('35000000-0000-0000-0000-000000000001', '31000000-0000-0000-0000-000000000001', '33000000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000003', '03000000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set org_id = excluded.org_id,
    property_id = excluded.property_id,
    user_id = excluded.user_id,
    granted_by = excluded.granted_by,
    deleted_at = excluded.deleted_at;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000002', true);
insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
values (
    '36000000-0000-0000-0000-000000000001',
    '31000000-0000-0000-0000-000000000001',
    null,
    null,
    '03000000-0000-0000-0000-000000000002',
    'member.accepted',
    '{"target_email":"org-viewer-13b@example.com"}'::jsonb
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36000000-0000-0000-0000-000000000001') = 1,
    'org-level event insert/read should work for active org member'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000003', true);
insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
values (
    '36000000-0000-0000-0000-000000000002',
    '31000000-0000-0000-0000-000000000001',
    null,
    '33000000-0000-0000-0000-000000000001',
    '03000000-0000-0000-0000-000000000003',
    'property.access.granted',
    '{"property_name":"Property Alpha 13B"}'::jsonb
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36000000-0000-0000-0000-000000000002') = 1,
    'property-level event insert/read should work for user with property access'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000006', true);
insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
values (
    '36000000-0000-0000-0000-000000000003',
    '31000000-0000-0000-0000-000000000001',
    '34000000-0000-0000-0000-000000000001',
    '33000000-0000-0000-0000-000000000001',
    '03000000-0000-0000-0000-000000000006',
    'session.started',
    '{"source":"verification"}'::jsonb
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36000000-0000-0000-0000-000000000003') = 1,
    'session-level event insert/read should still work'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000001', true);
insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
values (
    '36000000-0000-0000-0000-000000000004',
    '31000000-0000-0000-0000-000000000001',
    null,
    '33000000-0000-0000-0000-000000000002',
    '03000000-0000-0000-0000-000000000001',
    'property.access.revoked',
    '{"property_name":"Property Beta 13B"}'::jsonb
);
insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
values (
    '36000000-0000-0000-0000-000000000005',
    '31000000-0000-0000-0000-000000000001',
    '34000000-0000-0000-0000-000000000002',
    '33000000-0000-0000-0000-000000000002',
    '03000000-0000-0000-0000-000000000001',
    'session.exported',
    '{"property_name":"Property Beta 13B"}'::jsonb
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000003', true);
select public.test_assert(
    (select count(*) from public.session_events where id = '36000000-0000-0000-0000-000000000004') = 0,
    'property-scoped user should not read property event for ungranted property'
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36000000-0000-0000-0000-000000000003') = 1,
    'existing session-scoped event behavior should remain readable for granted-property session'
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36000000-0000-0000-0000-000000000005') = 0,
    'session-scoped event outside granted property should remain hidden'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000004', true);
select public.test_assert(
    (select count(*) from public.session_events where id = '36000000-0000-0000-0000-000000000001') = 1,
    'org-level event should be visible to active org member without property grants'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000005', true);
select public.test_assert(
    (select count(*) from public.session_events where id = '36000000-0000-0000-0000-000000000001') = 0,
    'revoked org member should not read org events'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000001', true);
select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
        values (
            '36000000-0000-0000-0000-000000000006',
            '31000000-0000-0000-0000-000000000001',
            null,
            '33000000-0000-0000-0000-000000000003',
            '03000000-0000-0000-0000-000000000001',
            'property.access.granted',
            '{}'::jsonb
        )
    $sql$,
    'property_id from another org should be rejected'
);
select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
        values (
            '36000000-0000-0000-0000-000000000007',
            '31000000-0000-0000-0000-000000000001',
            '34000000-0000-0000-0000-000000000003',
            null,
            '03000000-0000-0000-0000-000000000001',
            'session.started',
            '{}'::jsonb
        )
    $sql$,
    'session_id from another org should be rejected'
);
select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
        values (
            '36000000-0000-0000-0000-000000000008',
            '31000000-0000-0000-0000-000000000001',
            '34000000-0000-0000-0000-000000000002',
            '33000000-0000-0000-0000-000000000001',
            '03000000-0000-0000-0000-000000000001',
            'session.started',
            '{}'::jsonb
        )
    $sql$,
    'session_id and property_id mismatch should be rejected'
);

reset role;

drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

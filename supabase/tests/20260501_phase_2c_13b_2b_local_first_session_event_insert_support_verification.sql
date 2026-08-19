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
    ('03000000-0000-0000-0000-000000000011', 'authenticated', 'authenticated', 'owner-13b2b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000012', 'authenticated', 'authenticated', 'property-member-13b2b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000013', 'authenticated', 'authenticated', 'no-grant-13b2b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000014', 'authenticated', 'authenticated', 'revoked-13b2b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('03000000-0000-0000-0000-000000000011', 'owner-13b2b@example.com', 'Owner 13B2B', '03000000-0000-0000-0000-000000000011'),
    ('03000000-0000-0000-0000-000000000012', 'property-member-13b2b@example.com', 'Property Member 13B2B', '03000000-0000-0000-0000-000000000012'),
    ('03000000-0000-0000-0000-000000000013', 'no-grant-13b2b@example.com', 'No Grant 13B2B', '03000000-0000-0000-0000-000000000013'),
    ('03000000-0000-0000-0000-000000000014', 'revoked-13b2b@example.com', 'Revoked 13B2B', '03000000-0000-0000-0000-000000000014')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by)
values
    ('31200000-0000-0000-0000-000000000001', 'Audit Event Org A 13B2B', 'audit-event-org-a-13b2b', '03000000-0000-0000-0000-000000000011'),
    ('31200000-0000-0000-0000-000000000002', 'Audit Event Org B 13B2B', 'audit-event-org-b-13b2b', '03000000-0000-0000-0000-000000000011')
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('32200000-0000-0000-0000-000000000001', '31200000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000011', 'owner', 'org', '03000000-0000-0000-0000-000000000011', null),
    ('32200000-0000-0000-0000-000000000002', '31200000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000012', 'viewer', 'property', '03000000-0000-0000-0000-000000000011', null),
    ('32200000-0000-0000-0000-000000000003', '31200000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000013', 'viewer', 'property', '03000000-0000-0000-0000-000000000011', null),
    ('32200000-0000-0000-0000-000000000004', '31200000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000014', 'viewer', 'property', '03000000-0000-0000-0000-000000000011', timezone('utc', now())),
    ('32200000-0000-0000-0000-000000000005', '31200000-0000-0000-0000-000000000002', '03000000-0000-0000-0000-000000000011', 'owner', 'org', '03000000-0000-0000-0000-000000000011', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by)
values
    ('33200000-0000-0000-0000-000000000001', '31200000-0000-0000-0000-000000000001', 'Property Alpha 13B2B', '03000000-0000-0000-0000-000000000011'),
    ('33200000-0000-0000-0000-000000000002', '31200000-0000-0000-0000-000000000002', 'Property Beta 13B2B', '03000000-0000-0000-0000-000000000011')
on conflict (id) do update
set name = excluded.name,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.sessions (id, org_id, property_id, title, status, updated_by, deleted_at)
values
    ('34200000-0000-0000-0000-000000000001', '31200000-0000-0000-0000-000000000001', '33200000-0000-0000-0000-000000000001', 'Alpha Session 13B2B', 'draft', '03000000-0000-0000-0000-000000000011', null),
    ('34200000-0000-0000-0000-000000000002', '31200000-0000-0000-0000-000000000002', '33200000-0000-0000-0000-000000000002', 'Beta Session 13B2B', 'draft', '03000000-0000-0000-0000-000000000011', null)
on conflict (id) do update
set title = excluded.title,
    status = excluded.status,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.property_access_grants (id, org_id, property_id, user_id, granted_by, deleted_at)
values
    ('35200000-0000-0000-0000-000000000001', '31200000-0000-0000-0000-000000000001', '33200000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000012', '03000000-0000-0000-0000-000000000011', null)
on conflict (id) do update
set org_id = excluded.org_id,
    property_id = excluded.property_id,
    user_id = excluded.user_id,
    granted_by = excluded.granted_by,
    deleted_at = excluded.deleted_at;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000012', true);
select public.test_assert(
    public.has_property_access(
        '31200000-0000-0000-0000-000000000001',
        '33200000-0000-0000-0000-000000000001'
    ),
    'property-scoped user should have property access in verification setup'
);
select public.test_assert(
    public.session_event_insert_scope_valid(
        '31200000-0000-0000-0000-000000000001',
        '33200000-0000-0000-0000-000000000001',
        '34200000-0000-0000-0000-00000000aaaa'
    ),
    'local-first session event scope should be valid when the session row does not yet exist'
);
select public.test_assert(
    public.can_insert_session_event(
        '31200000-0000-0000-0000-000000000001',
        '33200000-0000-0000-0000-000000000001',
        '34200000-0000-0000-0000-00000000aaaa',
        null
    ),
    'property-scoped user should be allowed to insert local-first session event'
);
insert into public.session_events (id, org_id, session_id, property_id, event_type, payload)
values (
    '36200000-0000-0000-0000-000000000001',
    '31200000-0000-0000-0000-000000000001',
    '34200000-0000-0000-0000-00000000aaaa',
    '33200000-0000-0000-0000-000000000001',
    'session.started',
    '{}'::jsonb
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36200000-0000-0000-0000-000000000001') = 1,
    'property-scoped user with access should insert local-first session event when remote session row does not yet exist'
);
select public.test_assert(
    public.has_session_event_access(
        '31200000-0000-0000-0000-000000000001',
        '33200000-0000-0000-0000-000000000001',
        '34200000-0000-0000-0000-00000000aaaa'
    ),
    'same user should be able to read local-first session event after insert'
);

insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
values (
    '36200000-0000-0000-0000-000000000006',
    '31200000-0000-0000-0000-000000000001',
    '34200000-0000-0000-0000-00000000aaae',
    '33200000-0000-0000-0000-000000000001',
    '03000000-0000-0000-0000-000000000012',
    'session.locked',
    '{}'::jsonb
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36200000-0000-0000-0000-000000000006') = 1,
    'local-first session.locked insert should also work when the session row does not yet exist'
);

select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, event_type, payload)
        values (
            '36200000-0000-0000-0000-000000000002',
            '31200000-0000-0000-0000-000000000001',
            '34200000-0000-0000-0000-00000000aaab',
            '33200000-0000-0000-0000-000000000002',
            'session.locked',
            '{}'::jsonb
        )
    $sql$,
    'cross-org property should still be rejected for local-first session event'
);

select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, event_type, payload)
        values (
            '36200000-0000-0000-0000-000000000003',
            '31200000-0000-0000-0000-000000000001',
            '34200000-0000-0000-0000-000000000002',
            '33200000-0000-0000-0000-000000000001',
            'session.released',
            '{}'::jsonb
        )
    $sql$,
    'existing session row in different org/property must still be rejected'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000013', true);
select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, event_type, payload)
        values (
            '36200000-0000-0000-0000-000000000004',
            '31200000-0000-0000-0000-000000000001',
            '34200000-0000-0000-0000-00000000aaac',
            '33200000-0000-0000-0000-000000000001',
            'session.started',
            '{}'::jsonb
        )
    $sql$,
    'user without property access must not insert local-first session event'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000014', true);
select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, event_type, payload)
        values (
            '36200000-0000-0000-0000-000000000005',
            '31200000-0000-0000-0000-000000000001',
            '34200000-0000-0000-0000-00000000aaad',
            '33200000-0000-0000-0000-000000000001',
            'session.locked',
            '{}'::jsonb
        )
    $sql$,
    'revoked member must not insert local-first session event'
);

reset role;

drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

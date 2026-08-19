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
    ('03000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-13b2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'org-viewer-13b2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'property-member-13b2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'no-grant-13b2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('03000000-0000-0000-0000-000000000005', 'authenticated', 'authenticated', 'revoked-member-13b2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('03000000-0000-0000-0000-000000000001', 'owner-13b2@example.com', 'Owner 13B2', '03000000-0000-0000-0000-000000000001'),
    ('03000000-0000-0000-0000-000000000002', 'org-viewer-13b2@example.com', 'Org Viewer 13B2', '03000000-0000-0000-0000-000000000002'),
    ('03000000-0000-0000-0000-000000000003', 'property-member-13b2@example.com', 'Property Member 13B2', '03000000-0000-0000-0000-000000000003'),
    ('03000000-0000-0000-0000-000000000004', 'no-grant-13b2@example.com', 'No Grant 13B2', '03000000-0000-0000-0000-000000000004'),
    ('03000000-0000-0000-0000-000000000005', 'revoked-member-13b2@example.com', 'Revoked Member 13B2', '03000000-0000-0000-0000-000000000005')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by)
values
    ('31100000-0000-0000-0000-000000000001', 'Audit Event Org A 13B2', 'audit-event-org-a-13b2', '03000000-0000-0000-0000-000000000001'),
    ('31100000-0000-0000-0000-000000000002', 'Audit Event Org B 13B2', 'audit-event-org-b-13b2', '03000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('32100000-0000-0000-0000-000000000001', '31100000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000001', 'owner', 'org', '03000000-0000-0000-0000-000000000001', null),
    ('32100000-0000-0000-0000-000000000002', '31100000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000002', 'viewer', 'org', '03000000-0000-0000-0000-000000000001', null),
    ('32100000-0000-0000-0000-000000000003', '31100000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000003', 'viewer', 'property', '03000000-0000-0000-0000-000000000001', null),
    ('32100000-0000-0000-0000-000000000004', '31100000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000004', 'viewer', 'property', '03000000-0000-0000-0000-000000000001', null),
    ('32100000-0000-0000-0000-000000000005', '31100000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000005', 'viewer', 'org', '03000000-0000-0000-0000-000000000001', timezone('utc', now())),
    ('32100000-0000-0000-0000-000000000006', '31100000-0000-0000-0000-000000000002', '03000000-0000-0000-0000-000000000001', 'owner', 'org', '03000000-0000-0000-0000-000000000001', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by)
values
    ('33100000-0000-0000-0000-000000000001', '31100000-0000-0000-0000-000000000001', 'Property Alpha 13B2', '03000000-0000-0000-0000-000000000001'),
    ('33100000-0000-0000-0000-000000000002', '31100000-0000-0000-0000-000000000001', 'Property Beta 13B2', '03000000-0000-0000-0000-000000000001'),
    ('33100000-0000-0000-0000-000000000003', '31100000-0000-0000-0000-000000000002', 'Property Gamma 13B2', '03000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.sessions (id, org_id, property_id, title, status, updated_by, deleted_at)
values
    ('34100000-0000-0000-0000-000000000001', '31100000-0000-0000-0000-000000000001', '33100000-0000-0000-0000-000000000001', 'Alpha Session 13B2', 'draft', '03000000-0000-0000-0000-000000000001', null),
    ('34100000-0000-0000-0000-000000000002', '31100000-0000-0000-0000-000000000001', '33100000-0000-0000-0000-000000000002', 'Beta Session 13B2', 'draft', '03000000-0000-0000-0000-000000000001', null),
    ('34100000-0000-0000-0000-000000000003', '31100000-0000-0000-0000-000000000002', '33100000-0000-0000-0000-000000000003', 'Gamma Session 13B2', 'draft', '03000000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set title = excluded.title,
    status = excluded.status,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.property_access_grants (id, org_id, property_id, user_id, granted_by, deleted_at)
values
    ('35100000-0000-0000-0000-000000000001', '31100000-0000-0000-0000-000000000001', '33100000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000003', '03000000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set org_id = excluded.org_id,
    property_id = excluded.property_id,
    user_id = excluded.user_id,
    granted_by = excluded.granted_by,
    deleted_at = excluded.deleted_at;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000003', true);
insert into public.session_events (id, org_id, session_id, property_id, event_type, payload)
values (
    '36100000-0000-0000-0000-000000000001',
    '31100000-0000-0000-0000-000000000001',
    '34100000-0000-0000-0000-000000000001',
    '33100000-0000-0000-0000-000000000001',
    'session.started',
    '{}'::jsonb
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36100000-0000-0000-0000-000000000001') = 1,
    'property-scoped user with access should insert session.started using actor default'
);

insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
values (
    '36100000-0000-0000-0000-000000000002',
    '31100000-0000-0000-0000-000000000001',
    '34100000-0000-0000-0000-000000000001',
    '33100000-0000-0000-0000-000000000001',
    '03000000-0000-0000-0000-000000000003',
    'session.locked',
    '{}'::jsonb
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36100000-0000-0000-0000-000000000002') = 1,
    'property-scoped user with access should insert session.locked'
);

insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
values (
    '36100000-0000-0000-0000-000000000003',
    '31100000-0000-0000-0000-000000000001',
    '34100000-0000-0000-0000-000000000001',
    '33100000-0000-0000-0000-000000000001',
    '03000000-0000-0000-0000-000000000003',
    'session.released',
    '{}'::jsonb
);
select public.test_assert(
    (select count(*) from public.session_events where id = '36100000-0000-0000-0000-000000000003') = 1,
    'property-scoped user with access should insert session.released'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000004', true);
select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, event_type, payload)
        values (
            '36100000-0000-0000-0000-000000000004',
            '31100000-0000-0000-0000-000000000001',
            '34100000-0000-0000-0000-000000000001',
            '33100000-0000-0000-0000-000000000001',
            'session.started',
            '{}'::jsonb
        )
    $sql$,
    'user without property grant must not insert session event for inaccessible session'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000005', true);
select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, event_type, payload)
        values (
            '36100000-0000-0000-0000-000000000005',
            '31100000-0000-0000-0000-000000000001',
            '34100000-0000-0000-0000-000000000001',
            '33100000-0000-0000-0000-000000000001',
            'session.locked',
            '{}'::jsonb
        )
    $sql$,
    'revoked member must not insert session event'
);

select set_config('request.jwt.claim.sub', '03000000-0000-0000-0000-000000000001', true);
select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, event_type, payload)
        values (
            '36100000-0000-0000-0000-000000000006',
            '31100000-0000-0000-0000-000000000001',
            '34100000-0000-0000-0000-000000000003',
            '33100000-0000-0000-0000-000000000003',
            'session.released',
            '{}'::jsonb
        )
    $sql$,
    'cross-org session event insert must be rejected'
);

select public.test_expect_exception(
    $sql$
        insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
        values (
            '36100000-0000-0000-0000-000000000007',
            '31100000-0000-0000-0000-000000000001',
            '34100000-0000-0000-0000-000000000001',
            '33100000-0000-0000-0000-000000000001',
            '03000000-0000-0000-0000-000000000002',
            'session.started',
            '{}'::jsonb
        )
    $sql$,
    'actor_user_id must still match auth.uid() when provided'
);

reset role;

drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

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

create or replace function public.test_expect_denied(statement_text text, message text)
returns void
language plpgsql
as $$
begin
    execute statement_text;
    raise exception 'Expected denial: %', message;
exception
    when insufficient_privilege then
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
    ('00000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('00000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'manager@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('00000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'field@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('00000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'viewer@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('00000000-0000-0000-0000-000000000005', 'authenticated', 'authenticated', 'outsider@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('00000000-0000-0000-0000-000000000001', 'owner@example.com', 'Owner User', '00000000-0000-0000-0000-000000000001'),
    ('00000000-0000-0000-0000-000000000002', 'manager@example.com', 'Manager User', '00000000-0000-0000-0000-000000000002'),
    ('00000000-0000-0000-0000-000000000003', 'field@example.com', 'Field User', '00000000-0000-0000-0000-000000000003'),
    ('00000000-0000-0000-0000-000000000004', 'viewer@example.com', 'Viewer User', '00000000-0000-0000-0000-000000000004'),
    ('00000000-0000-0000-0000-000000000005', 'outsider@example.com', 'Outsider User', '00000000-0000-0000-0000-000000000005')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by)
values ('10000000-0000-0000-0000-000000000001', 'Test Org', 'test-org', '00000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by;

insert into public.org_memberships (id, org_id, user_id, role, updated_by)
values
    ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'owner', '00000000-0000-0000-0000-000000000001'),
    ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', 'manager', '00000000-0000-0000-0000-000000000001'),
    ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003', 'field', '00000000-0000-0000-0000-000000000001'),
    ('20000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', 'viewer', '00000000-0000-0000-0000-000000000001')
on conflict (org_id, user_id) do update
set role = excluded.role,
    updated_by = excluded.updated_by;

insert into public.properties (id, org_id, name, updated_by)
values ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Property One', '00000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    updated_by = excluded.updated_by;

insert into public.sessions (id, org_id, property_id, title, status, updated_by)
values ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Initial Session', 'draft', '00000000-0000-0000-0000-000000000001')
on conflict (id) do update
set title = excluded.title,
    status = excluded.status,
    updated_by = excluded.updated_by;

insert into public.shots (id, org_id, session_id, shot_type, position, updated_by)
values ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'overview', 1, '00000000-0000-0000-0000-000000000001')
on conflict (id) do update
set shot_type = excluded.shot_type,
    position = excluded.position,
    updated_by = excluded.updated_by;

insert into public.observations (id, org_id, session_id, shot_id, category, status, title, updated_by)
values ('60000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'condition', 'open', 'Initial Observation', '00000000-0000-0000-0000-000000000001')
on conflict (id) do update
set category = excluded.category,
    status = excluded.status,
    title = excluded.title,
    updated_by = excluded.updated_by;

insert into public.session_events (id, org_id, session_id, event_type, payload)
values ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'session.created', '{"source":"seed"}'::jsonb)
on conflict (id) do nothing;

set local role authenticated;

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select public.test_assert((select count(*) from public.orgs) = 1, 'owner should read org');
update public.orgs
set name = 'Owner Updated Org',
    updated_by = '00000000-0000-0000-0000-000000000001'
where id = '10000000-0000-0000-0000-000000000001';
select public.test_assert(exists (
    select 1
    from public.org_memberships
    where org_id = '10000000-0000-0000-0000-000000000001'
      and user_id = '00000000-0000-0000-0000-000000000004'
), 'owner should read memberships');
insert into public.org_memberships (id, org_id, user_id, role, updated_by)
values ('20000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000005', 'viewer', '00000000-0000-0000-0000-000000000001')
on conflict (org_id, user_id) do nothing;
update public.org_memberships
set deleted_at = timezone('utc', now()),
    updated_by = '00000000-0000-0000-0000-000000000001'
where id = '20000000-0000-0000-0000-000000000005';
select public.test_assert(exists (
    select 1
    from public.org_memberships
    where id = '20000000-0000-0000-0000-000000000005'
      and deleted_at is not null
), 'owner should be able to soft-delete membership via update');
insert into public.properties (id, org_id, name, updated_by)
values ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Owner Property', '00000000-0000-0000-0000-000000000001');
insert into public.session_events (id, org_id, session_id, event_type, payload)
values ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'owner.logged', '{"actor":"owner"}'::jsonb);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.test_assert((select count(*) from public.properties where org_id = '10000000-0000-0000-0000-000000000001') >= 1, 'manager should read properties');
update public.orgs
set name = 'Manager Updated Org',
    updated_by = '00000000-0000-0000-0000-000000000002'
where id = '10000000-0000-0000-0000-000000000001';
insert into public.properties (id, org_id, name, updated_by)
values ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Manager Property', '00000000-0000-0000-0000-000000000002');
update public.org_memberships
set role = 'field',
    updated_by = '00000000-0000-0000-0000-000000000002'
where id = '20000000-0000-0000-0000-000000000004';
select public.test_assert((
    select role
    from public.org_memberships
    where id = '20000000-0000-0000-0000-000000000004'
) = 'viewer', 'manager must not change memberships');
insert into public.session_events (id, org_id, session_id, event_type, payload)
values ('70000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'manager.logged', '{"actor":"manager"}'::jsonb);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);
select public.test_assert((select count(*) from public.sessions where org_id = '10000000-0000-0000-0000-000000000001') >= 1, 'field should read sessions');
insert into public.sessions (id, org_id, property_id, title, status, updated_by)
values ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'Field Session', 'draft', '00000000-0000-0000-0000-000000000003');
insert into public.shots (id, org_id, session_id, shot_type, position, updated_by)
values ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', 'detail', 1, '00000000-0000-0000-0000-000000000003');
insert into public.observations (id, org_id, session_id, shot_id, category, status, title, updated_by)
values ('60000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002', 'condition', 'open', 'Field Observation', '00000000-0000-0000-0000-000000000003');
select public.test_expect_denied(
    $sql$
        insert into public.properties (id, org_id, name, updated_by)
        values ('30000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'Field Property', '00000000-0000-0000-0000-000000000003')
    $sql$,
    'field must not insert properties'
);
insert into public.session_events (id, org_id, session_id, event_type, payload)
values ('70000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', 'field.logged', '{"actor":"field"}'::jsonb);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
select public.test_assert((select count(*) from public.shots where org_id = '10000000-0000-0000-0000-000000000001') >= 1, 'viewer should read shots');
update public.sessions
set title = 'Viewer Update Attempt',
    updated_by = '00000000-0000-0000-0000-000000000004'
where id = '40000000-0000-0000-0000-000000000001';
select public.test_assert((
    select title
    from public.sessions
    where id = '40000000-0000-0000-0000-000000000001'
) <> 'Viewer Update Attempt', 'viewer must not update sessions');
select public.test_expect_denied(
    $sql$
        insert into public.session_events (id, org_id, session_id, event_type, payload)
        values ('70000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'viewer.logged', '{}'::jsonb)
    $sql$,
    'viewer must not insert session events'
);
select public.test_assert((select count(*) from public.users_profile where id = '00000000-0000-0000-0000-000000000003') = 1, 'viewer should read shared-org user profiles');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000005', true);
select public.test_assert((select count(*) from public.orgs) = 0, 'outsider should not read orgs');
select public.test_assert((select count(*) from public.users_profile where id = '00000000-0000-0000-0000-000000000005') = 1, 'outsider should read own profile');
select public.test_assert((
    select count(*)
    from public.org_memberships
    where org_id = '10000000-0000-0000-0000-000000000001'
) = 0, 'outsider must not read org memberships');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select public.test_expect_denied(
    $sql$
        update public.session_events
        set event_type = 'mutated'
        where id = '70000000-0000-0000-0000-000000000001'
    $sql$,
    'session_events must reject update'
);
select public.test_expect_denied(
    $sql$
        delete from public.session_events
        where id = '70000000-0000-0000-0000-000000000001'
    $sql$,
    'session_events must reject delete'
);

reset role;

drop function public.test_expect_denied(text, text);
drop function public.test_assert(boolean, text);

rollback;

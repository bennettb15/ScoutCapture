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
    ('02000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-12b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('02000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'org-scope-12b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('02000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'property-scope-12b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('02000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'no-grant-12b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('02000000-0000-0000-0000-000000000005', 'authenticated', 'authenticated', 'revoked-grant-12b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('02000000-0000-0000-0000-000000000006', 'authenticated', 'authenticated', 'revoked-member-12b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('02000000-0000-0000-0000-000000000001', 'owner-12b@example.com', 'Owner 12B', '02000000-0000-0000-0000-000000000001'),
    ('02000000-0000-0000-0000-000000000002', 'org-scope-12b@example.com', 'Org Scope 12B', '02000000-0000-0000-0000-000000000002'),
    ('02000000-0000-0000-0000-000000000003', 'property-scope-12b@example.com', 'Property Scope 12B', '02000000-0000-0000-0000-000000000003'),
    ('02000000-0000-0000-0000-000000000004', 'no-grant-12b@example.com', 'No Grant 12B', '02000000-0000-0000-0000-000000000004'),
    ('02000000-0000-0000-0000-000000000005', 'revoked-grant-12b@example.com', 'Revoked Grant 12B', '02000000-0000-0000-0000-000000000005'),
    ('02000000-0000-0000-0000-000000000006', 'revoked-member-12b@example.com', 'Revoked Member 12B', '02000000-0000-0000-0000-000000000006')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by)
values ('21000000-0000-0000-0000-000000000001', 'Property Access Org', 'property-access-org', '02000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('22000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000001', 'owner', 'property', '02000000-0000-0000-0000-000000000001', null),
    ('22000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000002', 'viewer', 'org', '02000000-0000-0000-0000-000000000001', null),
    ('22000000-0000-0000-0000-000000000003', '21000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000003', 'viewer', 'property', '02000000-0000-0000-0000-000000000001', null),
    ('22000000-0000-0000-0000-000000000004', '21000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000004', 'viewer', 'property', '02000000-0000-0000-0000-000000000001', null),
    ('22000000-0000-0000-0000-000000000005', '21000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000005', 'viewer', 'property', '02000000-0000-0000-0000-000000000001', null),
    ('22000000-0000-0000-0000-000000000006', '21000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000006', 'viewer', 'property', '02000000-0000-0000-0000-000000000001', timezone('utc', now()))
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by)
values
    ('23000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', 'Property Alpha', '02000000-0000-0000-0000-000000000001'),
    ('23000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', 'Property Beta', '02000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.sessions (id, org_id, property_id, title, status, updated_by, deleted_at)
values
    ('24000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', '23000000-0000-0000-0000-000000000001', 'Alpha Session', 'draft', '02000000-0000-0000-0000-000000000001', null),
    ('24000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', '23000000-0000-0000-0000-000000000002', 'Beta Session', 'draft', '02000000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set title = excluded.title,
    status = excluded.status,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.shots (id, org_id, session_id, shot_type, position, updated_by, deleted_at)
values
    ('25000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000001', 'overview', 1, '02000000-0000-0000-0000-000000000001', null),
    ('25000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002', 'overview', 1, '02000000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set shot_type = excluded.shot_type,
    position = excluded.position,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.observations (id, org_id, session_id, shot_id, category, status, title, updated_by, deleted_at)
values
    ('26000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000001', 'condition', 'open', 'Alpha Observation', '02000000-0000-0000-0000-000000000001', null),
    ('26000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002', '25000000-0000-0000-0000-000000000002', 'condition', 'open', 'Beta Observation', '02000000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set category = excluded.category,
    status = excluded.status,
    title = excluded.title,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.session_events (id, org_id, session_id, event_type, payload)
values
    ('27000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000001', 'alpha.created', '{"property":"alpha"}'::jsonb),
    ('27000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002', 'beta.created', '{"property":"beta"}'::jsonb)
on conflict (id) do nothing;

insert into public.property_session_occupancy (property_id, org_id, occupied_by_user_id, occupied_by_device_id, occupied_at, updated_by)
values
    ('23000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000001', 'device-alpha', timezone('utc', now()), '02000000-0000-0000-0000-000000000001'),
    ('23000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000001', 'device-beta', timezone('utc', now()), '02000000-0000-0000-0000-000000000001')
on conflict (property_id) do update
set org_id = excluded.org_id,
    occupied_by_user_id = excluded.occupied_by_user_id,
    occupied_by_device_id = excluded.occupied_by_device_id,
    occupied_at = excluded.occupied_at,
    updated_by = excluded.updated_by;

insert into public.property_access_grants (id, org_id, property_id, user_id, granted_by, deleted_at)
values
    ('28000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001', '23000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000003', '02000000-0000-0000-0000-000000000001', null),
    ('28000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001', '23000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000005', '02000000-0000-0000-0000-000000000001', timezone('utc', now())),
    ('28000000-0000-0000-0000-000000000003', '21000000-0000-0000-0000-000000000001', '23000000-0000-0000-0000-000000000001', '02000000-0000-0000-0000-000000000006', '02000000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set org_id = excluded.org_id,
    property_id = excluded.property_id,
    user_id = excluded.user_id,
    granted_by = excluded.granted_by,
    deleted_at = excluded.deleted_at;

set local role authenticated;

select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '02000000-0000-0000-0000-000000000002', true);
select public.test_assert(
    (select count(*) from public.properties where org_id = '21000000-0000-0000-0000-000000000001') = 2,
    'org-scope member should still read all org properties'
);
select public.test_assert(
    (select count(*) from public.sessions where org_id = '21000000-0000-0000-0000-000000000001') = 2,
    'org-scope member should still read all org sessions'
);

select set_config('request.jwt.claim.sub', '02000000-0000-0000-0000-000000000003', true);
select public.test_assert(
    (select count(*) from public.properties where org_id = '21000000-0000-0000-0000-000000000001') = 1,
    'property-scope member with one grant should read exactly one property'
);
select public.test_assert(
    exists (
        select 1
        from public.properties
        where id = '23000000-0000-0000-0000-000000000001'
    ),
    'property-scope member should read the granted property'
);
select public.test_assert(
    (select count(*) from public.sessions where org_id = '21000000-0000-0000-0000-000000000001') = 1,
    'property-scope member should read only granted-property sessions'
);
select public.test_assert(
    (select count(*) from public.shots where org_id = '21000000-0000-0000-0000-000000000001') = 1,
    'property-scope member should read only granted-property shots'
);
select public.test_assert(
    (select count(*) from public.observations where org_id = '21000000-0000-0000-0000-000000000001') = 1,
    'property-scope member should read only granted-property observations'
);
select public.test_assert(
    (select count(*) from public.session_events where org_id = '21000000-0000-0000-0000-000000000001') = 1,
    'property-scope member should read only granted-property session events'
);
select public.test_assert(
    (select count(*) from public.property_session_occupancy where org_id = '21000000-0000-0000-0000-000000000001') = 1,
    'property-scope member should read only granted-property occupancy rows'
);

select set_config('request.jwt.claim.sub', '02000000-0000-0000-0000-000000000004', true);
select public.test_assert(
    (select count(*) from public.properties where org_id = '21000000-0000-0000-0000-000000000001') = 0,
    'property-scope member with no grants should read zero properties'
);
select public.test_assert(
    (select count(*) from public.sessions where org_id = '21000000-0000-0000-0000-000000000001') = 0,
    'property-scope member with no grants should read zero sessions'
);

select set_config('request.jwt.claim.sub', '02000000-0000-0000-0000-000000000005', true);
select public.test_assert(
    (select count(*) from public.properties where org_id = '21000000-0000-0000-0000-000000000001') = 0,
    'revoked property grant should remove property access'
);
select public.test_assert(
    (select count(*) from public.sessions where org_id = '21000000-0000-0000-0000-000000000001') = 0,
    'revoked property grant should remove related session access'
);

select set_config('request.jwt.claim.sub', '02000000-0000-0000-0000-000000000001', true);
select public.test_assert(
    (select count(*) from public.properties where org_id = '21000000-0000-0000-0000-000000000001') = 2,
    'owner should still read all properties even when membership is property-scoped'
);

select set_config('request.jwt.claim.sub', '02000000-0000-0000-0000-000000000006', true);
select public.test_assert(
    (select count(*) from public.properties where org_id = '21000000-0000-0000-0000-000000000001') = 0,
    'revoked org membership should read no properties'
);
select public.test_assert(
    (select count(*) from public.sessions where org_id = '21000000-0000-0000-0000-000000000001') = 0,
    'revoked org membership should read no sessions'
);
select public.test_assert(
    (select count(*) from public.property_access_grants where org_id = '21000000-0000-0000-0000-000000000001') = 0,
    'revoked org membership should not read grant rows'
);

reset role;

drop function public.test_assert(boolean, text);

rollback;

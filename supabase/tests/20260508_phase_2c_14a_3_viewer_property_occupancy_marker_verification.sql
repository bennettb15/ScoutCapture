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
        if sqlerrm like 'Expected exception:%' then
            raise;
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
    ('14a30000-0000-0000-0000-000000000101', 'authenticated', 'authenticated', 'owner-occupancy@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('14a30000-0000-0000-0000-000000000102', 'authenticated', 'authenticated', 'viewer-occupancy@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('14a30000-0000-0000-0000-000000000101', 'owner-occupancy@example.com', 'Owner Occupancy', '14a30000-0000-0000-0000-000000000101'),
    ('14a30000-0000-0000-0000-000000000102', 'viewer-occupancy@example.com', 'Viewer Occupancy', '14a30000-0000-0000-0000-000000000102')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by, deleted_at)
values ('14a31000-0000-0000-0000-000000000001', 'Viewer Occupancy Org', 'viewer-occupancy-org', '14a30000-0000-0000-0000-000000000101', null)
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('14a32000-0000-0000-0000-000000000101', '14a31000-0000-0000-0000-000000000001', '14a30000-0000-0000-0000-000000000101', 'owner', 'org', '14a30000-0000-0000-0000-000000000101', null),
    ('14a32000-0000-0000-0000-000000000102', '14a31000-0000-0000-0000-000000000001', '14a30000-0000-0000-0000-000000000102', 'viewer', 'org', '14a30000-0000-0000-0000-000000000101', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by, revision, deleted_at, is_archived)
values ('14a33000-0000-0000-0000-000000000001', '14a31000-0000-0000-0000-000000000001', 'Viewer Occupied Property', '14a30000-0000-0000-0000-000000000101', 1, null, false)
on conflict (id) do update
set org_id = excluded.org_id,
    name = excluded.name,
    updated_by = excluded.updated_by,
    revision = excluded.revision,
    deleted_at = excluded.deleted_at,
    is_archived = excluded.is_archived;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '14a30000-0000-0000-0000-000000000102', true);

insert into public.property_session_occupancy (
    property_id,
    org_id,
    occupied_by_user_id,
    occupied_by_device_id,
    occupied_at,
    updated_by
)
values (
    '14a33000-0000-0000-0000-000000000001',
    '14a31000-0000-0000-0000-000000000001',
    '14a30000-0000-0000-0000-000000000102',
    'viewer-device',
    timezone('utc', now()),
    '14a30000-0000-0000-0000-000000000102'
)
on conflict (property_id) do update
set occupied_by_user_id = excluded.occupied_by_user_id,
    occupied_by_device_id = excluded.occupied_by_device_id,
    occupied_at = excluded.occupied_at,
    updated_by = excluded.updated_by;

select public.test_assert(
    exists (
        select 1
        from public.property_session_occupancy
        where property_id = '14a33000-0000-0000-0000-000000000001'
          and occupied_by_user_id = '14a30000-0000-0000-0000-000000000102'
    ),
    'viewer should be able to persist a property occupancy marker'
);

select set_config('request.jwt.claim.sub', '14a30000-0000-0000-0000-000000000101', true);

select public.test_expect_exception(
    $$select public.soft_delete_property('14a33000-0000-0000-0000-000000000001')$$,
    'owner soft delete should block while viewer occupancy marker exists'
);

select public.test_assert(
    exists (
        select 1
        from public.properties
        where id = '14a33000-0000-0000-0000-000000000001'
          and deleted_at is null
    ),
    'blocked soft delete should leave viewer-occupied property undeleted'
);

select set_config('request.jwt.claim.sub', '14a30000-0000-0000-0000-000000000102', true);

delete from public.property_session_occupancy
where property_id = '14a33000-0000-0000-0000-000000000001';

select public.test_assert(
    not exists (
        select 1
        from public.property_session_occupancy
        where property_id = '14a33000-0000-0000-0000-000000000001'
    ),
    'viewer should be able to clear its property occupancy marker on exit'
);

reset role;

drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

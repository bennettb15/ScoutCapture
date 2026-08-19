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

create or replace function public.test_property_soft_delete_state(target_property_id uuid)
returns table (
    id uuid,
    deleted_at timestamptz,
    updated_by uuid,
    updated_at timestamptz,
    revision bigint,
    is_archived boolean
)
language sql
security definer
set search_path = public
as $$
    select property.id,
           property.deleted_at,
           property.updated_by,
           property.updated_at,
           property.revision,
           property.is_archived
    from public.properties property
    where property.id = target_property_id;
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
    ('14000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-14a@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('14000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'manager-14a@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('14000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'field-14a@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('14000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'viewer-14a@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('14000000-0000-0000-0000-000000000001', 'owner-14a@example.com', 'Owner 14A', '14000000-0000-0000-0000-000000000001'),
    ('14000000-0000-0000-0000-000000000002', 'manager-14a@example.com', 'Manager 14A', '14000000-0000-0000-0000-000000000002'),
    ('14000000-0000-0000-0000-000000000003', 'field-14a@example.com', 'Field 14A', '14000000-0000-0000-0000-000000000003'),
    ('14000000-0000-0000-0000-000000000004', 'viewer-14a@example.com', 'Viewer 14A', '14000000-0000-0000-0000-000000000004')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by)
values ('14100000-0000-0000-0000-000000000001', 'Property Soft Delete Org', 'property-soft-delete-org', '14000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('14200000-0000-0000-0000-000000000001', '14100000-0000-0000-0000-000000000001', '14000000-0000-0000-0000-000000000001', 'owner', 'org', '14000000-0000-0000-0000-000000000001', null),
    ('14200000-0000-0000-0000-000000000002', '14100000-0000-0000-0000-000000000001', '14000000-0000-0000-0000-000000000002', 'manager', 'org', '14000000-0000-0000-0000-000000000001', null),
    ('14200000-0000-0000-0000-000000000003', '14100000-0000-0000-0000-000000000001', '14000000-0000-0000-0000-000000000003', 'field', 'org', '14000000-0000-0000-0000-000000000001', null),
    ('14200000-0000-0000-0000-000000000004', '14100000-0000-0000-0000-000000000001', '14000000-0000-0000-0000-000000000004', 'viewer', 'org', '14000000-0000-0000-0000-000000000001', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (
    id,
    org_id,
    name,
    address_line1,
    city,
    state,
    postal_code,
    updated_at,
    updated_by,
    revision,
    deleted_at,
    is_archived
)
values
    ('14300000-0000-0000-0000-000000000001', '14100000-0000-0000-0000-000000000001', 'Owner Soft Delete Property', '1 Owner Way', 'Raleigh', 'NC', '27601', '2026-01-01T00:00:00Z', '14000000-0000-0000-0000-000000000001', 10, null, false),
    ('14300000-0000-0000-0000-000000000002', '14100000-0000-0000-0000-000000000001', 'Manager Soft Delete Property', '2 Manager Way', 'Raleigh', 'NC', '27602', '2026-01-01T00:00:00Z', '14000000-0000-0000-0000-000000000001', 20, null, false),
    ('14300000-0000-0000-0000-000000000003', '14100000-0000-0000-0000-000000000001', 'Archived Restore Property', '3 Archive Way', 'Raleigh', 'NC', '27603', '2026-01-01T00:00:00Z', '14000000-0000-0000-0000-000000000001', 30, null, true),
    ('14300000-0000-0000-0000-000000000004', '14100000-0000-0000-0000-000000000001', 'Occupied Property', '4 Occupied Way', 'Raleigh', 'NC', '27604', '2026-01-01T00:00:00Z', '14000000-0000-0000-0000-000000000001', 40, null, false)
on conflict (id) do update
set org_id = excluded.org_id,
    name = excluded.name,
    address_line1 = excluded.address_line1,
    city = excluded.city,
    state = excluded.state,
    postal_code = excluded.postal_code,
    updated_by = excluded.updated_by,
    revision = excluded.revision,
    deleted_at = excluded.deleted_at,
    is_archived = excluded.is_archived;

insert into public.property_session_occupancy (
    property_id,
    org_id,
    occupied_by_user_id,
    occupied_by_device_id,
    occupied_at,
    updated_by
)
values (
    '14300000-0000-0000-0000-000000000004',
    '14100000-0000-0000-0000-000000000001',
    '14000000-0000-0000-0000-000000000003',
    'field-device-14a',
    timezone('utc', now()),
    '14000000-0000-0000-0000-000000000003'
)
on conflict (property_id) do update
set org_id = excluded.org_id,
    occupied_by_user_id = excluded.occupied_by_user_id,
    occupied_by_device_id = excluded.occupied_by_device_id,
    occupied_at = excluded.occupied_at,
    updated_by = excluded.updated_by;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '14000000-0000-0000-0000-000000000001', true);
select public.soft_delete_property('14300000-0000-0000-0000-000000000001');
select public.test_assert(
    exists (
        select 1
        from public.test_property_soft_delete_state('14300000-0000-0000-0000-000000000001')
        where id = '14300000-0000-0000-0000-000000000001'
          and deleted_at is not null
          and updated_by = '14000000-0000-0000-0000-000000000001'
          and revision = 11
          and updated_at <> '2026-01-01T00:00:00Z'::timestamptz
    ),
    'owner soft delete should set deleted_at, updated_by, updated_at, and revision'
);
select public.soft_delete_property('14300000-0000-0000-0000-000000000001');
select public.test_assert(
    (
        select revision
        from public.test_property_soft_delete_state('14300000-0000-0000-0000-000000000001')
    ) = 11,
    'soft delete should be idempotent and not increment revision when already deleted'
);
select public.test_assert(
    not exists (
        select 1
        from public.properties
        where id = '14300000-0000-0000-0000-000000000001'
    ),
    'normal properties SELECT should hide deleted property'
);
select public.test_assert(
    exists (
        select 1
        from public.fetch_recently_deleted_properties('14100000-0000-0000-0000-000000000001')
        where id = '14300000-0000-0000-0000-000000000001'
          and org_id = '14100000-0000-0000-0000-000000000001'
          and name = 'Owner Soft Delete Property'
          and deleted_at is not null
          and revision = 11
          and is_archived = false
    ),
    'owner should fetch recently deleted property through RPC'
);
select public.restore_property('14300000-0000-0000-0000-000000000001');
select public.test_assert(
    exists (
        select 1
        from public.test_property_soft_delete_state('14300000-0000-0000-0000-000000000001')
        where id = '14300000-0000-0000-0000-000000000001'
          and deleted_at is null
          and updated_by = '14000000-0000-0000-0000-000000000001'
          and revision = 12
          and updated_at <> '2026-01-01T00:00:00Z'::timestamptz
    ),
    'owner restore should clear deleted_at, update updated_by/updated_at, and increment revision'
);
select public.restore_property('14300000-0000-0000-0000-000000000001');
select public.test_assert(
    (
        select revision
        from public.test_property_soft_delete_state('14300000-0000-0000-0000-000000000001')
    ) = 12,
    'restore should be idempotent and not increment revision when already restored'
);

select set_config('request.jwt.claim.sub', '14000000-0000-0000-0000-000000000002', true);
select public.soft_delete_property('14300000-0000-0000-0000-000000000002');
select public.test_assert(
    exists (
        select 1
        from public.fetch_recently_deleted_properties('14100000-0000-0000-0000-000000000001')
        where id = '14300000-0000-0000-0000-000000000002'
          and revision = 21
    ),
    'manager should soft delete and fetch recently deleted property'
);
select public.restore_property('14300000-0000-0000-0000-000000000002');
select public.test_assert(
    exists (
        select 1
        from public.test_property_soft_delete_state('14300000-0000-0000-0000-000000000002')
        where id = '14300000-0000-0000-0000-000000000002'
          and deleted_at is null
          and updated_by = '14000000-0000-0000-0000-000000000002'
          and revision = 22
    ),
    'manager should restore property'
);

select public.soft_delete_property('14300000-0000-0000-0000-000000000003');
select public.restore_property('14300000-0000-0000-0000-000000000003');
select public.test_assert(
    (
        select is_archived
        from public.test_property_soft_delete_state('14300000-0000-0000-0000-000000000003')
    ) = true,
    'restore must preserve is_archived'
);

select set_config('request.jwt.claim.sub', '14000000-0000-0000-0000-000000000003', true);
select public.test_expect_exception(
    $$select public.soft_delete_property('14300000-0000-0000-0000-000000000001')$$,
    'field must not soft delete property'
);
select public.test_expect_exception(
    $$select public.restore_property('14300000-0000-0000-0000-000000000001')$$,
    'field must not restore property'
);
select public.test_expect_exception(
    $$select count(*) from public.fetch_recently_deleted_properties('14100000-0000-0000-0000-000000000001')$$,
    'field must not fetch recently deleted properties'
);

select set_config('request.jwt.claim.sub', '14000000-0000-0000-0000-000000000004', true);
select public.test_expect_exception(
    $$select public.soft_delete_property('14300000-0000-0000-0000-000000000001')$$,
    'viewer must not soft delete property'
);
select public.test_expect_exception(
    $$select public.restore_property('14300000-0000-0000-0000-000000000001')$$,
    'viewer must not restore property'
);
select public.test_expect_exception(
    $$select count(*) from public.fetch_recently_deleted_properties('14100000-0000-0000-0000-000000000001')$$,
    'viewer must not fetch recently deleted properties'
);

select set_config('request.jwt.claim.sub', '14000000-0000-0000-0000-000000000001', true);
select public.test_expect_exception(
    $$select public.soft_delete_property('14300000-0000-0000-0000-000000000004')$$,
    'soft delete should block when active property occupancy exists'
);
select public.test_assert(
    exists (
        select 1
        from public.test_property_soft_delete_state('14300000-0000-0000-0000-000000000004')
        where id = '14300000-0000-0000-0000-000000000004'
          and deleted_at is null
          and revision = 40
    ),
    'occupancy-blocked soft delete should leave property unchanged'
);

select public.test_assert(
    (select count(*) from public.properties where org_id = '14100000-0000-0000-0000-000000000001') = 4,
    'soft delete and restore contract must not hard delete property rows'
);

reset role;

drop function public.test_property_soft_delete_state(uuid);
drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

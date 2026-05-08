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
    ('14900000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-14a3@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('14900000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'field-14a3@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('14900000-0000-0000-0000-000000000001', 'owner-14a3@example.com', 'Owner 14A3', '14900000-0000-0000-0000-000000000001'),
    ('14900000-0000-0000-0000-000000000002', 'field-14a3@example.com', 'Field 14A3', '14900000-0000-0000-0000-000000000002')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by, deleted_at)
values ('14910000-0000-0000-0000-000000000001', 'Property Lock Guard Org', 'property-lock-guard-org', '14900000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('14920000-0000-0000-0000-000000000001', '14910000-0000-0000-0000-000000000001', '14900000-0000-0000-0000-000000000001', 'owner', 'org', '14900000-0000-0000-0000-000000000001', null),
    ('14920000-0000-0000-0000-000000000002', '14910000-0000-0000-0000-000000000001', '14900000-0000-0000-0000-000000000002', 'field', 'org', '14900000-0000-0000-0000-000000000001', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by, revision, deleted_at, is_archived)
values
    ('14930000-0000-0000-0000-000000000001', '14910000-0000-0000-0000-000000000001', 'Locked Property', '14900000-0000-0000-0000-000000000001', 1, null, false),
    ('14930000-0000-0000-0000-000000000002', '14910000-0000-0000-0000-000000000001', 'Unlocked Property', '14900000-0000-0000-0000-000000000001', 1, null, false)
on conflict (id) do update
set org_id = excluded.org_id,
    name = excluded.name,
    updated_by = excluded.updated_by,
    revision = excluded.revision,
    deleted_at = excluded.deleted_at,
    is_archived = excluded.is_archived;

insert into public.sessions (
    id,
    org_id,
    property_id,
    title,
    status,
    updated_by,
    locked_by_user_id,
    locked_by_device_id,
    locked_at,
    deleted_at
)
values (
    '14940000-0000-0000-0000-000000000001',
    '14910000-0000-0000-0000-000000000001',
    '14930000-0000-0000-0000-000000000001',
    'Locked Session',
    'draft',
    '14900000-0000-0000-0000-000000000002',
    '14900000-0000-0000-0000-000000000002',
    'field-device',
    timezone('utc', now()),
    null
)
on conflict (id) do update
set org_id = excluded.org_id,
    property_id = excluded.property_id,
    title = excluded.title,
    status = excluded.status,
    updated_by = excluded.updated_by,
    locked_by_user_id = excluded.locked_by_user_id,
    locked_by_device_id = excluded.locked_by_device_id,
    locked_at = excluded.locked_at,
    deleted_at = excluded.deleted_at;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '14900000-0000-0000-0000-000000000001', true);

select public.test_expect_exception(
    $$select public.soft_delete_property('14930000-0000-0000-0000-000000000001')$$,
    'soft delete should block when an active session lock exists'
);

select public.test_assert(
    exists (
        select 1
        from public.properties
        where id = '14930000-0000-0000-0000-000000000001'
          and deleted_at is null
    ),
    'locked property should remain restored after blocked soft delete'
);

select public.soft_delete_property('14930000-0000-0000-0000-000000000002');
select public.test_assert(
    not exists (
        select 1
        from public.properties
        where id = '14930000-0000-0000-0000-000000000002'
    ),
    'unlocked soft-deleted property should be hidden from normal SELECT'
);

reset role;

drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

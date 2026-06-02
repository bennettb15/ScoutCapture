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

create temp table expected_public_table_grants (
    table_name text primary key,
    authenticated_select boolean not null default false,
    authenticated_insert boolean not null default false,
    authenticated_update boolean not null default false,
    authenticated_delete boolean not null default false,
    service_select boolean not null default true,
    service_insert boolean not null default true,
    service_update boolean not null default true,
    service_delete boolean not null default true
);

insert into expected_public_table_grants (
    table_name,
    authenticated_select,
    authenticated_insert,
    authenticated_update,
    authenticated_delete
)
values
    ('orgs', true, false, true, false),
    ('users_profile', true, true, true, false),
    ('org_memberships', true, true, true, false),
    ('properties', true, true, true, false),
    ('sessions', true, true, true, false),
    ('shots', true, true, true, false),
    ('observations', true, true, true, false),
    ('session_events', true, true, false, false),
    ('org_invitations', true, false, false, false),
    ('property_access_grants', true, true, true, false),
    ('property_session_occupancy', true, true, true, true),
    ('session_snapshots', true, true, false, false),
    ('property_status', true, false, false, false);

select public.test_assert(
    not exists (
        select 1
        from expected_public_table_grants expected
        where to_regclass('public.' || expected.table_name) is null
    ),
    'all audited public tables should exist'
);

select public.test_assert(
    not exists (
        select 1
        from expected_public_table_grants expected
        where has_table_privilege('anon', 'public.' || expected.table_name, 'SELECT')
           or has_table_privilege('anon', 'public.' || expected.table_name, 'INSERT')
           or has_table_privilege('anon', 'public.' || expected.table_name, 'UPDATE')
           or has_table_privilege('anon', 'public.' || expected.table_name, 'DELETE')
    ),
    'anon must not have direct table privileges on audited public tables'
);

select public.test_assert(
    not exists (
        select 1
        from expected_public_table_grants expected
        where has_table_privilege('authenticated', 'public.' || expected.table_name, 'SELECT') <> expected.authenticated_select
           or has_table_privilege('authenticated', 'public.' || expected.table_name, 'INSERT') <> expected.authenticated_insert
           or has_table_privilege('authenticated', 'public.' || expected.table_name, 'UPDATE') <> expected.authenticated_update
           or has_table_privilege('authenticated', 'public.' || expected.table_name, 'DELETE') <> expected.authenticated_delete
    ),
    'authenticated table privileges should match audited expected grants'
);

select public.test_assert(
    not exists (
        select 1
        from expected_public_table_grants expected
        where has_table_privilege('service_role', 'public.' || expected.table_name, 'SELECT') <> expected.service_select
           or has_table_privilege('service_role', 'public.' || expected.table_name, 'INSERT') <> expected.service_insert
           or has_table_privilege('service_role', 'public.' || expected.table_name, 'UPDATE') <> expected.service_update
           or has_table_privilege('service_role', 'public.' || expected.table_name, 'DELETE') <> expected.service_delete
    ),
    'service_role table privileges should include full audited operational access'
);

select public.test_assert(
    not exists (
        select 1
        from expected_public_table_grants expected
        join pg_class class
          on class.oid = ('public.' || expected.table_name)::regclass
        join pg_namespace namespace
          on namespace.oid = class.relnamespace
        where namespace.nspname = 'public'
          and class.relkind in ('r', 'p')
          and class.relrowsecurity is not true
    ),
    'all audited public tables should have RLS enabled'
);

select public.test_assert(
    has_table_privilege('authenticated', 'public.session_snapshots', 'SELECT')
    and has_table_privilege('authenticated', 'public.session_snapshots', 'INSERT')
    and not has_table_privilege('authenticated', 'public.session_snapshots', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.session_snapshots', 'DELETE')
    and has_table_privilege('service_role', 'public.session_snapshots', 'SELECT')
    and has_table_privilege('service_role', 'public.session_snapshots', 'INSERT')
    and has_table_privilege('service_role', 'public.session_snapshots', 'UPDATE')
    and has_table_privilege('service_role', 'public.session_snapshots', 'DELETE'),
    'session_snapshots grants should remain append/read for authenticated and full access for service_role'
);

select public.test_assert(
    not exists (
        select 1
        from information_schema.table_privileges privilege
        where privilege.table_schema = 'public'
          and privilege.grantee = 'anon'
          and privilege.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
          and privilege.table_name in (
              select table_name
              from expected_public_table_grants
          )
    ),
    'no broad accidental anon exposure should exist on audited tables'
);

rollback;

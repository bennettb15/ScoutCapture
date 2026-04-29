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
    raise exception 'Expected failure: %', message;
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
    ('01000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-12a@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('01000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'invitee-12a@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('01000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'member-12a@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('01000000-0000-0000-0000-000000000001', 'owner-12a@example.com', 'Owner 12A', '01000000-0000-0000-0000-000000000001'),
    ('01000000-0000-0000-0000-000000000002', 'invitee-12a@example.com', 'Invitee 12A', '01000000-0000-0000-0000-000000000002'),
    ('01000000-0000-0000-0000-000000000003', 'member-12a@example.com', 'Member 12A', '01000000-0000-0000-0000-000000000003')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by)
values ('11000000-0000-0000-0000-000000000001', 'Org Access Test', 'org-access-test', '01000000-0000-0000-0000-000000000001')
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by;

insert into public.org_memberships (id, org_id, user_id, role, updated_by)
values
    ('12000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001', '01000000-0000-0000-0000-000000000001', 'owner', '01000000-0000-0000-0000-000000000001'),
    ('12000000-0000-0000-0000-000000000002', '11000000-0000-0000-0000-000000000001', '01000000-0000-0000-0000-000000000003', 'viewer', '01000000-0000-0000-0000-000000000001')
on conflict (org_id, user_id) do update
set role = excluded.role,
    updated_by = excluded.updated_by,
    deleted_at = null;

set local role authenticated;

select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '01000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.email', 'owner-12a@example.com', true);

select public.create_org_invitation(
    '11000000-0000-0000-0000-000000000001',
    'invitee-12a@example.com',
    'viewer'
);

select public.test_expect_exception(
    $sql$
        select public.create_org_invitation(
            '11000000-0000-0000-0000-000000000001',
            'invitee-12a@example.com',
            'viewer'
        )
    $sql$,
    'duplicate pending invites must be blocked'
);

select public.test_assert(
    (
        select count(*)
        from public.org_invitations
        where org_id = '11000000-0000-0000-0000-000000000001'
          and lower(invitee_email) = 'invitee-12a@example.com'
          and accepted_at is null
          and revoked_at is null
    ) = 1,
    'owner invite should create exactly one active pending invite'
);

select set_config('request.jwt.claim.sub', '01000000-0000-0000-0000-000000000002', true);
select set_config('request.jwt.claim.email', 'invitee-12a@example.com', true);

select public.test_assert(
    (
        select count(*)
        from public.list_pending_org_invitations()
        where org_id = '11000000-0000-0000-0000-000000000001'
    ) = 1,
    'invitee should read pending invites through rpc'
);

select public.accept_org_invitation(
    (
        select id
        from public.org_invitations
        where org_id = '11000000-0000-0000-0000-000000000001'
          and lower(invitee_email) = 'invitee-12a@example.com'
          and accepted_at is null
          and revoked_at is null
        limit 1
    )
);

select public.test_assert(
    exists (
        select 1
        from public.org_memberships
        where org_id = '11000000-0000-0000-0000-000000000001'
          and user_id = '01000000-0000-0000-0000-000000000002'
          and role = 'viewer'
          and deleted_at is null
    ),
    'accept invite should activate org membership'
);

select public.test_assert(
    exists (
        select 1
        from public.org_invitations
        where org_id = '11000000-0000-0000-0000-000000000001'
          and lower(invitee_email) = 'invitee-12a@example.com'
          and accepted_at is not null
    ),
    'accept invite should mark invitation as accepted'
);

select set_config('request.jwt.claim.sub', '01000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.email', 'owner-12a@example.com', true);

select public.revoke_org_access(
    '11000000-0000-0000-0000-000000000001',
    '01000000-0000-0000-0000-000000000003',
    null
);

select public.test_assert(
    exists (
        select 1
        from public.org_memberships
        where org_id = '11000000-0000-0000-0000-000000000001'
          and user_id = '01000000-0000-0000-0000-000000000003'
          and deleted_at is not null
    ),
    'owner revoke should soft-delete membership'
);

select public.create_org_invitation(
    '11000000-0000-0000-0000-000000000001',
    'revoked-12a@example.com',
    'viewer'
);

select public.revoke_org_access(
    '11000000-0000-0000-0000-000000000001',
    null,
    (
        select id
        from public.org_invitations
        where org_id = '11000000-0000-0000-0000-000000000001'
          and lower(invitee_email) = 'revoked-12a@example.com'
          and accepted_at is null
          and revoked_at is null
        limit 1
    )
);

select public.test_assert(
    exists (
        select 1
        from public.org_invitations
        where org_id = '11000000-0000-0000-0000-000000000001'
          and lower(invitee_email) = 'revoked-12a@example.com'
          and revoked_at is not null
    ),
    'owner revoke should revoke pending invite'
);

reset role;

drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

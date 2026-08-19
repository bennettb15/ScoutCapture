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

create or replace function public.test_expect_rejected(statement_text text, message text)
returns void
language plpgsql
as $$
begin
    execute statement_text;
    raise exception 'Expected rejection: %', message;
exception
    when insufficient_privilege
        or check_violation
        or with_check_option_violation
        or invalid_text_representation
        or foreign_key_violation
        or unique_violation then
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
    ('23d00000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-23d@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('23d00000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'manager-23d@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('23d00000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'field-23d@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('23d00000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'viewer-23d@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('23d00000-0000-0000-0000-000000000005', 'authenticated', 'authenticated', 'outsider-23d@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('23d00000-0000-0000-0000-000000000006', 'authenticated', 'authenticated', 'other-owner-23d@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('23d00000-0000-0000-0000-000000000001', 'owner-23d@example.com', '23D Owner', '23d00000-0000-0000-0000-000000000001'),
    ('23d00000-0000-0000-0000-000000000002', 'manager-23d@example.com', '23D Manager', '23d00000-0000-0000-0000-000000000002'),
    ('23d00000-0000-0000-0000-000000000003', 'field-23d@example.com', '23D Field', '23d00000-0000-0000-0000-000000000003'),
    ('23d00000-0000-0000-0000-000000000004', 'viewer-23d@example.com', '23D Viewer', '23d00000-0000-0000-0000-000000000004'),
    ('23d00000-0000-0000-0000-000000000005', 'outsider-23d@example.com', '23D Outsider', '23d00000-0000-0000-0000-000000000005'),
    ('23d00000-0000-0000-0000-000000000006', 'other-owner-23d@example.com', '23D Other Owner', '23d00000-0000-0000-0000-000000000006')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by)
values
    ('23d10000-0000-0000-0000-000000000001', '23D Org', '23d-org', '23d00000-0000-0000-0000-000000000001'),
    ('23d10000-0000-0000-0000-000000000002', '23D Other Org', '23d-other-org', '23d00000-0000-0000-0000-000000000006')
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by)
values
    ('23d20000-0000-0000-0000-000000000001', '23d10000-0000-0000-0000-000000000001', '23d00000-0000-0000-0000-000000000001', 'owner', 'org', '23d00000-0000-0000-0000-000000000001'),
    ('23d20000-0000-0000-0000-000000000002', '23d10000-0000-0000-0000-000000000001', '23d00000-0000-0000-0000-000000000002', 'manager', 'org', '23d00000-0000-0000-0000-000000000001'),
    ('23d20000-0000-0000-0000-000000000003', '23d10000-0000-0000-0000-000000000001', '23d00000-0000-0000-0000-000000000003', 'field', 'org', '23d00000-0000-0000-0000-000000000001'),
    ('23d20000-0000-0000-0000-000000000004', '23d10000-0000-0000-0000-000000000001', '23d00000-0000-0000-0000-000000000004', 'viewer', 'org', '23d00000-0000-0000-0000-000000000001'),
    ('23d20000-0000-0000-0000-000000000006', '23d10000-0000-0000-0000-000000000002', '23d00000-0000-0000-0000-000000000006', 'owner', 'org', '23d00000-0000-0000-0000-000000000006')
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.properties (id, org_id, name, updated_by)
values
    ('23d30000-0000-0000-0000-000000000001', '23d10000-0000-0000-0000-000000000001', '23D Property', '23d00000-0000-0000-0000-000000000001'),
    ('23d30000-0000-0000-0000-000000000002', '23d10000-0000-0000-0000-000000000002', '23D Other Property', '23d00000-0000-0000-0000-000000000006')
on conflict (id) do update
set name = excluded.name,
    updated_by = excluded.updated_by,
    deleted_at = null;

insert into public.sessions (id, org_id, property_id, title, status, updated_by)
values
    ('23d40000-0000-0000-0000-000000000001', '23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23D Session', 'completed', '23d00000-0000-0000-0000-000000000001'),
    ('23d40000-0000-0000-0000-000000000002', '23d10000-0000-0000-0000-000000000002', '23d30000-0000-0000-0000-000000000002', '23D Other Session', 'completed', '23d00000-0000-0000-0000-000000000006')
on conflict (id) do update
set title = excluded.title,
    status = excluded.status,
    updated_by = excluded.updated_by,
    deleted_at = null;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '23d00000-0000-0000-0000-000000000001', true);
insert into public.session_snapshots (
    id,
    org_id,
    property_id,
    session_id,
    snapshot_kind,
    snapshot_schema_version,
    session_metadata_schema_version,
    trigger,
    session_status,
    is_sealed,
    payload_storage_bucket,
    payload_storage_path,
    payload_byte_size,
    raw_session_json_sha256,
    snapshot_payload_sha256,
    created_by,
    updated_by
)
values (
    '23d50000-0000-0000-0000-000000000001',
    '23d10000-0000-0000-0000-000000000001',
    '23d30000-0000-0000-0000-000000000001',
    '23d40000-0000-0000-0000-000000000001',
    'completed',
    1,
    12,
    'preview',
    'completed',
    true,
    'scoutcapture-session-snapshots',
    public.session_snapshot_expected_storage_path(
        '23d10000-0000-0000-0000-000000000001',
        '23d30000-0000-0000-0000-000000000001',
        '23d40000-0000-0000-0000-000000000001',
        'completed',
        '23d50000-0000-0000-0000-000000000001'
    ),
    128,
    repeat('a', 64),
    repeat('b', 64),
    '23d00000-0000-0000-0000-000000000001',
    '23d00000-0000-0000-0000-000000000001'
);
select public.test_assert(
    exists (select 1 from public.session_snapshots where id = '23d50000-0000-0000-0000-000000000001'),
    'owner should insert snapshot row'
);

select set_config('request.jwt.claim.sub', '23d00000-0000-0000-0000-000000000002', true);
insert into public.session_snapshots (
    id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
    payload_storage_bucket, payload_storage_path, payload_byte_size,
    raw_session_json_sha256, snapshot_payload_sha256, created_by, updated_by
)
values (
    '23d50000-0000-0000-0000-000000000002',
    '23d10000-0000-0000-0000-000000000001',
    '23d30000-0000-0000-0000-000000000001',
    '23d40000-0000-0000-0000-000000000001',
    'draft',
    1,
    'preview',
    'scoutcapture-session-snapshots',
    public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'draft', '23d50000-0000-0000-0000-000000000002'),
    128,
    repeat('c', 64),
    repeat('d', 64),
    '23d00000-0000-0000-0000-000000000002',
    '23d00000-0000-0000-0000-000000000002'
);
select public.test_assert(
    exists (select 1 from public.session_snapshots where id = '23d50000-0000-0000-0000-000000000002'),
    'manager should insert snapshot row'
);

select set_config('request.jwt.claim.sub', '23d00000-0000-0000-0000-000000000003', true);
insert into public.session_snapshots (
    id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
    payload_storage_bucket, payload_storage_path, payload_byte_size,
    raw_session_json_sha256, snapshot_payload_sha256, created_by, updated_by
)
values (
    '23d50000-0000-0000-0000-000000000003',
    '23d10000-0000-0000-0000-000000000001',
    '23d30000-0000-0000-0000-000000000001',
    '23d40000-0000-0000-0000-000000000001',
    'draft',
    1,
    'preview',
    'scoutcapture-session-snapshots',
    public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'draft', '23d50000-0000-0000-0000-000000000003'),
    128,
    repeat('e', 64),
    repeat('f', 64),
    '23d00000-0000-0000-0000-000000000003',
    '23d00000-0000-0000-0000-000000000003'
);
select public.test_assert(
    exists (select 1 from public.session_snapshots where id = '23d50000-0000-0000-0000-000000000003'),
    'field should insert snapshot row'
);

select set_config('request.jwt.claim.sub', '23d00000-0000-0000-0000-000000000004', true);
select public.test_assert(
    (select count(*) from public.session_snapshots where session_id = '23d40000-0000-0000-0000-000000000001') = 3,
    'viewer should select visible snapshot rows'
);
select public.test_expect_rejected(
    $sql$
        insert into public.session_snapshots (
            id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
            payload_storage_bucket, payload_storage_path, payload_byte_size,
            raw_session_json_sha256, snapshot_payload_sha256, created_by, updated_by
        )
        values (
            '23d50000-0000-0000-0000-000000000004',
            '23d10000-0000-0000-0000-000000000001',
            '23d30000-0000-0000-0000-000000000001',
            '23d40000-0000-0000-0000-000000000001',
            'draft',
            1,
            'preview',
            'scoutcapture-session-snapshots',
            public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'draft', '23d50000-0000-0000-0000-000000000004'),
            128,
            repeat('1', 64),
            repeat('2', 64),
            '23d00000-0000-0000-0000-000000000004',
            '23d00000-0000-0000-0000-000000000004'
        )
    $sql$,
    'viewer must not insert snapshot rows'
);

select set_config('request.jwt.claim.sub', '23d00000-0000-0000-0000-000000000005', true);
select public.test_assert(
    (select count(*) from public.session_snapshots where session_id = '23d40000-0000-0000-0000-000000000001') = 0,
    'outsider must not select snapshot rows'
);
select public.test_expect_rejected(
    $sql$
        insert into public.session_snapshots (
            id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
            payload_storage_bucket, payload_storage_path, payload_byte_size,
            raw_session_json_sha256, snapshot_payload_sha256, created_by, updated_by
        )
        values (
            '23d50000-0000-0000-0000-000000000005',
            '23d10000-0000-0000-0000-000000000001',
            '23d30000-0000-0000-0000-000000000001',
            '23d40000-0000-0000-0000-000000000001',
            'draft',
            1,
            'preview',
            'scoutcapture-session-snapshots',
            public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'draft', '23d50000-0000-0000-0000-000000000005'),
            128,
            repeat('3', 64),
            repeat('4', 64),
            '23d00000-0000-0000-0000-000000000005',
            '23d00000-0000-0000-0000-000000000005'
        )
    $sql$,
    'outsider must not insert snapshot rows'
);

select set_config('request.jwt.claim.sub', '23d00000-0000-0000-0000-000000000001', true);
select public.test_expect_rejected(
    $sql$
        insert into public.session_snapshots (
            id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
            payload_storage_bucket, payload_storage_path, payload_byte_size,
            raw_session_json_sha256, snapshot_payload_sha256, created_by, updated_by
        )
        values (
            '23d50000-0000-0000-0000-000000000006',
            '23d10000-0000-0000-0000-000000000001',
            '23d30000-0000-0000-0000-000000000001',
            '23d40000-0000-0000-0000-000000000002',
            'draft',
            1,
            'preview',
            'scoutcapture-session-snapshots',
            public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000002', 'draft', '23d50000-0000-0000-0000-000000000006'),
            128,
            repeat('5', 64),
            repeat('6', 64),
            '23d00000-0000-0000-0000-000000000001',
            '23d00000-0000-0000-0000-000000000001'
        )
    $sql$,
    'invalid org/property/session combination must be rejected'
);

select public.test_expect_rejected(
    $sql$
        insert into public.session_snapshots (
            id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
            payload_storage_bucket, payload_storage_path, payload_byte_size,
            raw_session_json_sha256, snapshot_payload_sha256, created_by, updated_by
        )
        values (
            '23d50000-0000-0000-0000-000000000007',
            '23d10000-0000-0000-0000-000000000001',
            '23d30000-0000-0000-0000-000000000001',
            '23d40000-0000-0000-0000-000000000001',
            'draft',
            1,
            'preview',
            'scoutcapture-session-snapshots',
            public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'draft', '23d50000-0000-0000-0000-000000000007'),
            128,
            'not-a-sha',
            repeat('7', 64),
            '23d00000-0000-0000-0000-000000000001',
            '23d00000-0000-0000-0000-000000000001'
        )
    $sql$,
    'invalid checksum length must be rejected'
);

select public.test_expect_rejected(
    $sql$
        insert into public.session_snapshots (
            id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
            payload_storage_bucket, payload_storage_path, payload_byte_size,
            raw_session_json_sha256, snapshot_payload_sha256, created_by, updated_by
        )
        values (
            '23d50000-0000-0000-0000-000000000008',
            '23d10000-0000-0000-0000-000000000001',
            '23d30000-0000-0000-0000-000000000001',
            '23d40000-0000-0000-0000-000000000001',
            'draft',
            1,
            'preview',
            'scoutcapture-originals',
            public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'draft', '23d50000-0000-0000-0000-000000000008'),
            128,
            repeat('8', 64),
            repeat('9', 64),
            '23d00000-0000-0000-0000-000000000001',
            '23d00000-0000-0000-0000-000000000001'
        )
    $sql$,
    'invalid bucket must be rejected'
);

select public.test_expect_rejected(
    $sql$
        update public.session_snapshots
        set trigger = 'mutated',
            updated_by = '23d00000-0000-0000-0000-000000000001'
        where id = '23d50000-0000-0000-0000-000000000001'
    $sql$,
    'authenticated app clients must not update snapshot rows'
);
select public.test_assert(
    (select trigger from public.session_snapshots where id = '23d50000-0000-0000-0000-000000000001') = 'preview',
    'authenticated app clients must not update snapshot rows'
);
select public.test_expect_rejected(
    $sql$
        delete from public.session_snapshots
        where id = '23d50000-0000-0000-0000-000000000001'
    $sql$,
    'authenticated app clients must not delete snapshot rows'
);

insert into storage.objects (id, bucket_id, name, owner)
values (
    '23d60000-0000-0000-0000-000000000001',
    'scoutcapture-session-snapshots',
    public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'completed', '23d50000-0000-0000-0000-000000000001'),
    '23d00000-0000-0000-0000-000000000001'
);
select public.test_assert(
    (select count(*) from storage.objects where id = '23d60000-0000-0000-0000-000000000001') = 1,
    'owner should insert matching snapshot storage object'
);
select public.test_assert(
    (select count(*) from storage.objects where id = '23d60000-0000-0000-0000-000000000001') = 1,
    'owner should select snapshot object with matching visible row'
);

select public.test_expect_rejected(
    $sql$
        insert into storage.objects (id, bucket_id, name, owner)
        values (
            '23d60000-0000-0000-0000-000000000002',
            'scoutcapture-session-snapshots',
            'bad-prefix/23d10000-0000-0000-0000-000000000001/properties/23d30000-0000-0000-0000-000000000001/sessions/23d40000-0000-0000-0000-000000000001/snapshots/draft/23d50000-0000-0000-0000-000000000009.json',
            '23d00000-0000-0000-0000-000000000001'
        )
    $sql$,
    'wrong storage path prefix must be denied'
);

select set_config('request.jwt.claim.sub', '23d00000-0000-0000-0000-000000000004', true);
select public.test_expect_rejected(
    $sql$
        insert into storage.objects (id, bucket_id, name, owner)
        values (
            '23d60000-0000-0000-0000-000000000003',
            'scoutcapture-session-snapshots',
            public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'draft', '23d50000-0000-0000-0000-000000000010'),
            '23d00000-0000-0000-0000-000000000004'
        )
    $sql$,
    'viewer must not insert snapshot storage objects'
);
select public.test_assert(
    (select count(*) from storage.objects where id = '23d60000-0000-0000-0000-000000000001') = 1,
    'viewer should select snapshot object with matching visible row'
);

select set_config('request.jwt.claim.sub', '23d00000-0000-0000-0000-000000000005', true);
select public.test_assert(
    (select count(*) from storage.objects where id = '23d60000-0000-0000-0000-000000000001') = 0,
    'outsider must not select snapshot storage objects'
);

reset role;

set local role anon;
select set_config('request.jwt.claim.role', 'anon', true);
select set_config('request.jwt.claim.sub', '', true);
select public.test_expect_rejected(
    $sql$
        select count(*) from public.session_snapshots
    $sql$,
    'anon must not read session_snapshots'
);
select public.test_expect_rejected(
    $sql$
        insert into public.session_snapshots (
            id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
            payload_storage_bucket, payload_storage_path, payload_byte_size,
            raw_session_json_sha256, snapshot_payload_sha256
        )
        values (
            '23d50000-0000-0000-0000-000000000011',
            '23d10000-0000-0000-0000-000000000001',
            '23d30000-0000-0000-0000-000000000001',
            '23d40000-0000-0000-0000-000000000001',
            'draft',
            1,
            'preview',
            'scoutcapture-session-snapshots',
            public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'draft', '23d50000-0000-0000-0000-000000000011'),
            128,
            repeat('a', 64),
            repeat('b', 64)
        )
    $sql$,
    'anon must not insert session_snapshots'
);
select public.test_expect_rejected(
    $sql$
        insert into storage.objects (id, bucket_id, name)
        values (
            '23d60000-0000-0000-0000-000000000004',
            'scoutcapture-session-snapshots',
            public.session_snapshot_expected_storage_path('23d10000-0000-0000-0000-000000000001', '23d30000-0000-0000-0000-000000000001', '23d40000-0000-0000-0000-000000000001', 'draft', '23d50000-0000-0000-0000-000000000012')
        )
    $sql$,
    'anon must not insert snapshot storage objects'
);

rollback;

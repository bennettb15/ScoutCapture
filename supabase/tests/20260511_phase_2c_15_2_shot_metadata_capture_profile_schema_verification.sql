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

create or replace function public.test_15_2_shot_state(target_shot_id uuid)
returns table (
    id uuid,
    building text,
    storage_path text,
    deleted_at timestamptz
)
language sql
security definer
set search_path = public
as $$
    select shot.id,
           shot.building,
           shot.storage_path,
           shot.deleted_at
    from public.shots shot
    where shot.id = target_shot_id;
$$;

create or replace function public.test_15_2_session_state(target_session_id uuid)
returns table (
    id uuid,
    deleted_at timestamptz,
    updated_by uuid,
    revision bigint
)
language sql
security definer
set search_path = public
as $$
    select session_row.id,
           session_row.deleted_at,
           session_row.updated_by,
           session_row.revision
    from public.sessions session_row
    where session_row.id = target_session_id;
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
    ('15c20000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-15-2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('15c20000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'manager-15-2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('15c20000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'field-15-2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('15c20000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'viewer-15-2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('15c20000-0000-0000-0000-000000000001', 'owner-15-2@example.com', 'Owner 15-2', '15c20000-0000-0000-0000-000000000001'),
    ('15c20000-0000-0000-0000-000000000002', 'manager-15-2@example.com', 'Manager 15-2', '15c20000-0000-0000-0000-000000000002'),
    ('15c20000-0000-0000-0000-000000000003', 'field-15-2@example.com', 'Field 15-2', '15c20000-0000-0000-0000-000000000003'),
    ('15c20000-0000-0000-0000-000000000004', 'viewer-15-2@example.com', 'Viewer 15-2', '15c20000-0000-0000-0000-000000000004')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by, deleted_at)
values ('15c21000-0000-0000-0000-000000000001', 'Phase 2C 15-2 Org', 'phase-2c-15-2-org', '15c20000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('15c22000-0000-0000-0000-000000000001', '15c21000-0000-0000-0000-000000000001', '15c20000-0000-0000-0000-000000000001', 'owner', 'org', '15c20000-0000-0000-0000-000000000001', null),
    ('15c22000-0000-0000-0000-000000000002', '15c21000-0000-0000-0000-000000000001', '15c20000-0000-0000-0000-000000000002', 'manager', 'org', '15c20000-0000-0000-0000-000000000001', null),
    ('15c22000-0000-0000-0000-000000000003', '15c21000-0000-0000-0000-000000000001', '15c20000-0000-0000-0000-000000000003', 'field', 'org', '15c20000-0000-0000-0000-000000000001', null),
    ('15c22000-0000-0000-0000-000000000004', '15c21000-0000-0000-0000-000000000001', '15c20000-0000-0000-0000-000000000004', 'viewer', 'org', '15c20000-0000-0000-0000-000000000001', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, capture_profile, updated_by, deleted_at)
values ('15c23000-0000-0000-0000-000000000001', '15c21000-0000-0000-0000-000000000001', 'Phase 2C 15-2 Property', null, '15c20000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set name = excluded.name,
    capture_profile = excluded.capture_profile,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.sessions (
    id,
    org_id,
    property_id,
    title,
    status,
    started_at,
    capture_profile,
    updated_by,
    deleted_at
)
values ('15c24000-0000-0000-0000-000000000001', '15c21000-0000-0000-0000-000000000001', '15c23000-0000-0000-0000-000000000001', 'Phase 2C 15-2 Session', 'draft', '2026-05-11T12:00:00Z', null, '15c20000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set title = excluded.title,
    status = excluded.status,
    started_at = excluded.started_at,
    capture_profile = excluded.capture_profile,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.shots (
    id,
    org_id,
    property_id,
    session_id,
    shot_type,
    position,
    captured_at,
    storage_bucket,
    storage_path,
    checksum_sha256,
    byte_size,
    upload_state,
    upload_attempts,
    building,
    elevation,
    detail_type,
    angle_index,
    shot_key,
    logical_shot_identity,
    capture_kind,
    first_capture_kind,
    is_guided,
    is_flagged,
    issue_status,
    trade,
    reason,
    priority,
    capture_mode,
    lens,
    latitude,
    longitude,
    accuracy_meters,
    image_width,
    image_height,
    updated_by,
    deleted_at
)
values (
    '15c25000-0000-0000-0000-000000000001',
    '15c21000-0000-0000-0000-000000000001',
    '15c23000-0000-0000-0000-000000000001',
    '15c24000-0000-0000-0000-000000000001',
    'detail',
    1,
    '2026-05-11T12:05:00Z',
    'scoutcapture-originals',
    'sessions/15c24000-0000-0000-0000-000000000001/shots/15c25000-0000-0000-0000-000000000001/original.heic',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    12345,
    'uploaded',
    2,
    'Building A',
    'North',
    'Window',
    1,
    'building a|north|window|1',
    '15c24000-0000-0000-0000-000000000001|normal|building a|north|window|1',
    'captured',
    'captured',
    true,
    false,
    null,
    null,
    null,
    null,
    'hd',
    'wide',
    37.7749,
    -122.4194,
    8.5,
    4032,
    3024,
    '15c20000-0000-0000-0000-000000000001',
    null
)
on conflict (id) do update
set property_id = excluded.property_id,
    session_id = excluded.session_id,
    storage_bucket = excluded.storage_bucket,
    storage_path = excluded.storage_path,
    checksum_sha256 = excluded.checksum_sha256,
    byte_size = excluded.byte_size,
    upload_state = excluded.upload_state,
    upload_attempts = excluded.upload_attempts,
    building = excluded.building,
    elevation = excluded.elevation,
    detail_type = excluded.detail_type,
    angle_index = excluded.angle_index,
    shot_key = excluded.shot_key,
    logical_shot_identity = excluded.logical_shot_identity,
    capture_kind = excluded.capture_kind,
    first_capture_kind = excluded.first_capture_kind,
    is_guided = excluded.is_guided,
    is_flagged = excluded.is_flagged,
    issue_status = excluded.issue_status,
    trade = excluded.trade,
    reason = excluded.reason,
    priority = excluded.priority,
    capture_mode = excluded.capture_mode,
    lens = excluded.lens,
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    accuracy_meters = excluded.accuracy_meters,
    image_width = excluded.image_width,
    image_height = excluded.image_height,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '15c20000-0000-0000-0000-000000000001', true);

update public.properties
set capture_profile = 'residential',
    updated_by = '15c20000-0000-0000-0000-000000000001'
where id = '15c23000-0000-0000-0000-000000000001';
select public.test_assert(
    (select capture_profile from public.properties where id = '15c23000-0000-0000-0000-000000000001') = 'residential',
    'owner should update properties.capture_profile'
);

select public.test_expect_exception(
    $sql$
        update public.properties
        set capture_profile = 'mixed-use',
            updated_by = '15c20000-0000-0000-0000-000000000001'
        where id = '15c23000-0000-0000-0000-000000000001'
    $sql$,
    'invalid properties.capture_profile should fail'
);

update public.sessions
set capture_profile = 'residential',
    updated_by = '15c20000-0000-0000-0000-000000000001'
where id = '15c24000-0000-0000-0000-000000000001';
select public.test_assert(
    (select capture_profile from public.sessions where id = '15c24000-0000-0000-0000-000000000001') = 'residential',
    'owner should update sessions.capture_profile'
);

select public.test_expect_exception(
    $sql$
        update public.sessions
        set capture_profile = 'mixed-use',
            updated_by = '15c20000-0000-0000-0000-000000000001'
        where id = '15c24000-0000-0000-0000-000000000001'
    $sql$,
    'invalid sessions.capture_profile should fail'
);

update public.shots
set building = 'Owner Building',
    elevation = 'South',
    detail_type = 'Door',
    angle_index = 2,
    shot_key = 'owner building|south|door|2',
    logical_shot_identity = '15c24000-0000-0000-0000-000000000001|normal|owner building|south|door|2',
    capture_kind = 'reclassified',
    priority = 'High',
    updated_by = '15c20000-0000-0000-0000-000000000001'
where id = '15c25000-0000-0000-0000-000000000001';
select public.test_assert(
    exists (
        select 1
        from public.shots
        where id = '15c25000-0000-0000-0000-000000000001'
          and building = 'Owner Building'
          and storage_bucket = 'scoutcapture-originals'
          and storage_path like 'sessions/%/original.heic'
          and checksum_sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
          and upload_state = 'uploaded'
    ),
    'rich shot metadata update should preserve storage metadata'
);

select public.test_expect_exception(
    $sql$
        update public.shots
        set priority = 'Urgent',
            updated_by = '15c20000-0000-0000-0000-000000000001'
        where id = '15c25000-0000-0000-0000-000000000001'
    $sql$,
    'invalid shot priority should fail'
);

select public.test_expect_exception(
    $sql$
        update public.shots
        set capture_kind = 'unknown_capture',
            updated_by = '15c20000-0000-0000-0000-000000000001'
        where id = '15c25000-0000-0000-0000-000000000001'
    $sql$,
    'invalid shot capture_kind should fail'
);

select public.test_expect_exception(
    $sql$
        update public.shots
        set first_capture_kind = 'retake',
            updated_by = '15c20000-0000-0000-0000-000000000001'
        where id = '15c25000-0000-0000-0000-000000000001'
    $sql$,
    'invalid shot first_capture_kind should fail'
);

select public.test_expect_exception(
    $sql$
        update public.shots
        set angle_index = -1,
            updated_by = '15c20000-0000-0000-0000-000000000001'
        where id = '15c25000-0000-0000-0000-000000000001'
    $sql$,
    'negative shot angle_index should fail'
);

select set_config('request.jwt.claim.sub', '15c20000-0000-0000-0000-000000000002', true);

update public.properties
set capture_profile = 'commercial',
    updated_by = '15c20000-0000-0000-0000-000000000002'
where id = '15c23000-0000-0000-0000-000000000001';
select public.test_assert(
    (select capture_profile from public.properties where id = '15c23000-0000-0000-0000-000000000001') = 'commercial',
    'manager should update properties.capture_profile'
);

update public.sessions
set capture_profile = 'commercial',
    updated_by = '15c20000-0000-0000-0000-000000000002'
where id = '15c24000-0000-0000-0000-000000000001';
select public.test_assert(
    (select capture_profile from public.sessions where id = '15c24000-0000-0000-0000-000000000001') = 'commercial',
    'manager should update sessions.capture_profile'
);

update public.shots
set trade = 'Electrical',
    reason = 'Loose cover',
    is_flagged = true,
    is_guided = false,
    issue_status = 'active',
    updated_by = '15c20000-0000-0000-0000-000000000002'
where id = '15c25000-0000-0000-0000-000000000001';
select public.test_assert(
    exists (
        select 1
        from public.shots
        where id = '15c25000-0000-0000-0000-000000000001'
          and trade = 'Electrical'
          and reason = 'Loose cover'
          and is_flagged
          and not is_guided
    ),
    'manager should update rich shot metadata'
);

update public.shots
set storage_bucket = 'scoutcapture-originals',
    storage_path = 'sessions/15c24000-0000-0000-0000-000000000001/shots/15c25000-0000-0000-0000-000000000001/reuploaded.heic',
    checksum_sha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    byte_size = 45678,
    upload_state = 'uploaded',
    upload_attempts = 3,
    last_upload_error = null,
    updated_by = '15c20000-0000-0000-0000-000000000002'
where id = '15c25000-0000-0000-0000-000000000001';
select public.test_assert(
    exists (
        select 1
        from public.shots
        where id = '15c25000-0000-0000-0000-000000000001'
          and storage_path like '%/reuploaded.heic'
          and building = 'Owner Building'
          and detail_type = 'Door'
          and trade = 'Electrical'
          and reason = 'Loose cover'
    ),
    'storage metadata update should preserve rich shot metadata'
);

select set_config('request.jwt.claim.sub', '15c20000-0000-0000-0000-000000000003', true);

select public.test_expect_exception(
    $sql$
        update public.shots
        set building = 'Missing Updated By Contract'
        where id = '15c25000-0000-0000-0000-000000000001'
    $sql$,
    'shot metadata update without matching updated_by should expose current updated_by RLS contract'
);

update public.sessions
set capture_profile = 'residential',
    updated_by = '15c20000-0000-0000-0000-000000000003'
where id = '15c24000-0000-0000-0000-000000000001';
select public.test_assert(
    (select capture_profile from public.sessions where id = '15c24000-0000-0000-0000-000000000001') = 'residential',
    'field should update sessions.capture_profile under current session update policy'
);

update public.properties
set capture_profile = 'residential',
    updated_by = '15c20000-0000-0000-0000-000000000003'
where id = '15c23000-0000-0000-0000-000000000001';
select public.test_assert(
    (select capture_profile from public.properties where id = '15c23000-0000-0000-0000-000000000001') = 'commercial',
    'field should not update properties.capture_profile under current property update policy'
);

update public.shots
set capture_kind = 'retake',
    first_capture_kind = 'captured',
    updated_by = '15c20000-0000-0000-0000-000000000003'
where id = '15c25000-0000-0000-0000-000000000001';
select public.test_assert(
    (select capture_kind from public.shots where id = '15c25000-0000-0000-0000-000000000001') = 'retake',
    'field should update shot metadata under current shot update policy'
);

insert into public.shots (
    id,
    org_id,
    property_id,
    session_id,
    building,
    elevation,
    detail_type,
    angle_index,
    shot_key,
    logical_shot_identity,
    capture_kind,
    first_capture_kind,
    is_guided,
    is_flagged,
    priority,
    updated_by
)
values (
    '15c25000-0000-0000-0000-000000000002',
    '15c21000-0000-0000-0000-000000000001',
    '15c23000-0000-0000-0000-000000000001',
    '15c24000-0000-0000-0000-000000000001',
    'Field Building',
    'East',
    'Roofline',
    0,
    'field building|east|roofline|0',
    '15c24000-0000-0000-0000-000000000001|normal|field building|east|roofline|0',
    'captured',
    'captured',
    true,
    false,
    'Low',
    '15c20000-0000-0000-0000-000000000003'
);
select public.test_assert(
    exists (
        select 1
        from public.shots
        where id = '15c25000-0000-0000-0000-000000000002'
          and property_id = '15c23000-0000-0000-0000-000000000001'
          and angle_index = 0
          and priority = 'Low'
    ),
    'field should insert valid rich shot metadata with matching updated_by'
);

insert into public.shots (
    id,
    org_id,
    property_id,
    session_id,
    building,
    angle_index,
    updated_by
)
values (
    '15c25000-0000-0000-0000-000000000003',
    '15c21000-0000-0000-0000-000000000001',
    '15c23000-0000-0000-0000-000000000001',
    '15c24000-0000-0000-0000-000000000001',
    'Null Updated By Insert',
    1,
    null
);
select public.test_assert(
    exists (
        select 1
        from public.shots
        where id = '15c25000-0000-0000-0000-000000000003'
          and building = 'Null Updated By Insert'
          and updated_by is null
    ),
    'shot insert without updated_by is currently allowed because updated_by_matches_actor permits null'
);

select set_config('request.jwt.claim.sub', '15c20000-0000-0000-0000-000000000004', true);

update public.properties
set capture_profile = 'residential',
    updated_by = '15c20000-0000-0000-0000-000000000004'
where id = '15c23000-0000-0000-0000-000000000001';
select public.test_assert(
    (select capture_profile from public.properties where id = '15c23000-0000-0000-0000-000000000001') = 'commercial',
    'viewer should not update properties.capture_profile'
);

update public.sessions
set capture_profile = 'commercial',
    updated_by = '15c20000-0000-0000-0000-000000000004'
where id = '15c24000-0000-0000-0000-000000000001';
select public.test_assert(
    (select capture_profile from public.sessions where id = '15c24000-0000-0000-0000-000000000001') = 'residential',
    'viewer should not update sessions.capture_profile'
);

update public.shots
set building = 'Viewer Building',
    updated_by = '15c20000-0000-0000-0000-000000000004'
where id = '15c25000-0000-0000-0000-000000000001';
select public.test_assert(
    (select building from public.shots where id = '15c25000-0000-0000-0000-000000000001') = 'Owner Building',
    'viewer should not update shot metadata'
);

select set_config('request.jwt.claim.sub', '15c20000-0000-0000-0000-000000000001', true);

select public.soft_delete_session('15c24000-0000-0000-0000-000000000001');
select public.test_assert(
    exists (
        select 1
        from public.test_15_2_session_state('15c24000-0000-0000-0000-000000000001')
        where id = '15c24000-0000-0000-0000-000000000001'
          and deleted_at is not null
          and updated_by = '15c20000-0000-0000-0000-000000000001'
    ),
    'existing session soft delete behavior should still mark sessions.deleted_at'
);
select public.test_assert(
    exists (
        select 1
        from public.test_15_2_shot_state('15c25000-0000-0000-0000-000000000001')
        where id = '15c25000-0000-0000-0000-000000000001'
          and building = 'Owner Building'
          and storage_path like '%/reuploaded.heic'
    ),
    'session soft delete should not hard delete or mutate shot metadata'
);

select public.restore_session('15c24000-0000-0000-0000-000000000001');
select public.test_assert(
    exists (
        select 1
        from public.test_15_2_session_state('15c24000-0000-0000-0000-000000000001')
        where id = '15c24000-0000-0000-0000-000000000001'
          and deleted_at is null
    ),
    'existing session restore behavior should still clear sessions.deleted_at'
);

reset role;

drop function public.test_15_2_session_state(uuid);
drop function public.test_15_2_shot_state(uuid);
drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

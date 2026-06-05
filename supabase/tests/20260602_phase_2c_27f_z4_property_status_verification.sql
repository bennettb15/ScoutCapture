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
    ('27f00000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'status-a@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('27f00000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'status-b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('27f00000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'status-viewer@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('27f00000-0000-0000-0000-000000000001', 'status-a@example.com', 'Status A', '27f00000-0000-0000-0000-000000000001'),
    ('27f00000-0000-0000-0000-000000000002', 'status-b@example.com', 'Status B', '27f00000-0000-0000-0000-000000000002'),
    ('27f00000-0000-0000-0000-000000000003', 'status-viewer@example.com', 'Status Viewer', '27f00000-0000-0000-0000-000000000003')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by, deleted_at)
values ('27f10000-0000-0000-0000-000000000001', 'Property Status Org', 'property-status-org', '27f00000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('27f20000-0000-0000-0000-000000000001', '27f10000-0000-0000-0000-000000000001', '27f00000-0000-0000-0000-000000000001', 'field', 'org', '27f00000-0000-0000-0000-000000000001', null),
    ('27f20000-0000-0000-0000-000000000002', '27f10000-0000-0000-0000-000000000001', '27f00000-0000-0000-0000-000000000002', 'field', 'org', '27f00000-0000-0000-0000-000000000001', null),
    ('27f20000-0000-0000-0000-000000000003', '27f10000-0000-0000-0000-000000000001', '27f00000-0000-0000-0000-000000000003', 'viewer', 'org', '27f00000-0000-0000-0000-000000000001', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by, revision, deleted_at, is_archived)
values
    ('27f30000-0000-0000-0000-000000000001', '27f10000-0000-0000-0000-000000000001', 'Status Occupancy', '27f00000-0000-0000-0000-000000000001', 1, null, false),
    ('27f30000-0000-0000-0000-000000000002', '27f10000-0000-0000-0000-000000000001', 'Status Draft', '27f00000-0000-0000-0000-000000000001', 1, null, false),
    ('27f30000-0000-0000-0000-000000000003', '27f10000-0000-0000-0000-000000000001', 'Status Release', '27f00000-0000-0000-0000-000000000001', 1, null, false),
    ('27f30000-0000-0000-0000-000000000004', '27f10000-0000-0000-0000-000000000001', 'Status Rebuild', '27f00000-0000-0000-0000-000000000001', 1, null, false)
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
    started_at,
    completed_at,
    updated_by,
    is_sealed,
    locked_by_user_id,
    locked_by_device_id,
    locked_at,
    deleted_at
)
values
    ('27f40000-0000-0000-0000-000000000002', '27f10000-0000-0000-0000-000000000001', '27f30000-0000-0000-0000-000000000002', 'Draft Session', 'draft', timezone('utc', now()), null, '27f00000-0000-0000-0000-000000000001', false, '27f00000-0000-0000-0000-000000000001', 'device-a', timezone('utc', now()), null),
    ('27f40000-0000-0000-0000-000000000003', '27f10000-0000-0000-0000-000000000001', '27f30000-0000-0000-0000-000000000003', 'Release Session', 'draft', timezone('utc', now()), null, '27f00000-0000-0000-0000-000000000001', false, null, null, null, null),
    ('27f40000-0000-0000-0000-000000000004', '27f10000-0000-0000-0000-000000000001', '27f30000-0000-0000-0000-000000000004', 'Rebuild Draft Session', 'draft', timezone('utc', now()), null, '27f00000-0000-0000-0000-000000000001', false, '27f00000-0000-0000-0000-000000000001', 'device-a', timezone('utc', now()), null)
on conflict (id) do update
set org_id = excluded.org_id,
    property_id = excluded.property_id,
    title = excluded.title,
    status = excluded.status,
    started_at = excluded.started_at,
    completed_at = excluded.completed_at,
    updated_by = excluded.updated_by,
    is_sealed = excluded.is_sealed,
    locked_by_user_id = excluded.locked_by_user_id,
    locked_by_device_id = excluded.locked_by_device_id,
    locked_at = excluded.locked_at,
    deleted_at = excluded.deleted_at;

insert into public.shots (id, org_id, session_id, shot_type, position, updated_by, deleted_at)
values ('27f50000-0000-0000-0000-000000000004', '27f10000-0000-0000-0000-000000000001', '27f40000-0000-0000-0000-000000000004', 'overview', 1, '27f00000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set org_id = excluded.org_id,
    session_id = excluded.session_id,
    shot_type = excluded.shot_type,
    position = excluded.position,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.property_session_occupancy (
    property_id,
    org_id,
    occupied_by_user_id,
    occupied_by_device_id,
    occupied_at,
    updated_by
)
values (
    '27f30000-0000-0000-0000-000000000004',
    '27f10000-0000-0000-0000-000000000001',
    '27f00000-0000-0000-0000-000000000002',
    'device-b',
    timezone('utc', now()),
    '27f00000-0000-0000-0000-000000000002'
)
on conflict (property_id) do update
set org_id = excluded.org_id,
    occupied_by_user_id = excluded.occupied_by_user_id,
    occupied_by_device_id = excluded.occupied_by_device_id,
    occupied_at = excluded.occupied_at,
    updated_by = excluded.updated_by;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000001', true);

select public.test_assert(
    has_table_privilege('authenticated', 'public.property_status', 'SELECT')
    and not has_table_privilege('authenticated', 'public.property_status', 'INSERT')
    and not has_table_privilege('authenticated', 'public.property_status', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.property_status', 'DELETE'),
    'authenticated actors should read property_status but write only through RPCs'
);

select public.test_expect_exception(
    $$insert into public.property_status (property_id, org_id, status, updated_by) values ('27f30000-0000-0000-0000-000000000001', '27f10000-0000-0000-0000-000000000001', 'idle', '27f00000-0000-0000-0000-000000000001')$$,
    'direct authenticated insert should be denied'
);

select public.claim_property_status(
    '27f30000-0000-0000-0000-000000000001',
    '27f4aaaa-0000-0000-0000-000000000001',
    'device-a',
    'test:transient-zero-photo-claim'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '27f30000-0000-0000-0000-000000000001'
          and status = 'occupied'
          and active_session_id = '27f4aaaa-0000-0000-0000-000000000001'
          and owner_user_id = '27f00000-0000-0000-0000-000000000001'
          and owner_device_id = 'device-a'
    ),
    'claim should persist occupied status with a transient zero-photo session id'
);

select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000002', true);

select public.test_expect_exception(
    $$select public.claim_property_status('27f30000-0000-0000-0000-000000000001', '27f4bbbb-0000-0000-0000-000000000001', 'device-b', 'test:b-blocked')$$,
    'fresh occupancy should block a different actor'
);

reset role;

select public.test_assert(
    not public.property_status_is_stale('occupied', timezone('utc', now()) - interval '2 minutes'),
    'occupied property_status should remain fresh inside the 3 minute ttl'
);

select public.test_assert(
    public.property_status_is_stale('occupied', timezone('utc', now()) - interval '4 minutes'),
    'occupied property_status should become stale after the 3 minute ttl'
);

select public.test_assert(
    not public.property_status_is_stale('draft', timezone('utc', now()) - interval '4 minutes'),
    'draft property_status should not auto-expire through stale ttl'
);

select public.test_assert(
    not public.property_status_is_stale('pending_export', timezone('utc', now()) - interval '4 minutes'),
    'pending_export property_status should not auto-expire through stale ttl'
);

update public.property_status
set heartbeat_at = timezone('utc', now()) - interval '4 minutes'
where property_id = '27f30000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000002', true);

select public.claim_property_status(
    '27f30000-0000-0000-0000-000000000001',
    '27f4bbbb-0000-0000-0000-000000000001',
    'device-b',
    'test:stale-override'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '27f30000-0000-0000-0000-000000000001'
          and status = 'occupied'
          and active_session_id = '27f4bbbb-0000-0000-0000-000000000001'
          and owner_user_id = '27f00000-0000-0000-0000-000000000002'
          and owner_device_id = 'device-b'
    ),
    'stale occupied status should be claimable by another allowed actor'
);

select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000001', true);

select public.test_expect_exception(
    $$select public.promote_property_status_draft('27f30000-0000-0000-0000-000000000002', '27f4cccc-0000-0000-0000-000000000002', 'device-a', 'test:missing-draft-session')$$,
    'draft promotion should still require a matching remote session'
);

select public.promote_property_status_draft(
    '27f30000-0000-0000-0000-000000000002',
    '27f40000-0000-0000-0000-000000000002',
    'device-a',
    'test:promote-draft'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '27f30000-0000-0000-0000-000000000002'
          and status = 'draft'
          and draft_session_id = '27f40000-0000-0000-0000-000000000002'
          and owner_user_id = '27f00000-0000-0000-0000-000000000001'
          and owner_device_id = 'device-a'
    ),
    'promote draft should persist draft session and owner identity'
);

select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000002', true);

select public.test_expect_exception(
    $$select public.claim_property_status('27f30000-0000-0000-0000-000000000002', null, 'device-b', 'test:draft-blocks-claim')$$,
    'unresolved draft should block a different actor from claiming the property'
);

select public.test_expect_exception(
    $$select public.set_property_status_pending_export('27f30000-0000-0000-0000-000000000002', '27f40000-0000-0000-0000-000000000002', 'device-b', 'test:non-owner-pending')$$,
    'non-owner should not finalize another actor draft even with the same session id'
);

select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000001', true);

select public.test_expect_exception(
    $$select public.set_property_status_pending_export('27f30000-0000-0000-0000-000000000002', '27f4cccc-0000-0000-0000-000000000002', 'device-a', 'test:missing-pending-session')$$,
    'pending export should still require a matching remote session'
);

select public.test_expect_exception(
    $$select public.set_property_status_exported('27f30000-0000-0000-0000-000000000002', '27f4cccc-0000-0000-0000-000000000002', 'device-a', 'test:missing-exported-session')$$,
    'exported should still require a matching remote session'
);

select public.test_assert(
    public.property_status_actor_owns('27f00000-0000-0000-0000-000000000001', 'device-a', 'device-a-other'),
    'same user on a different device should own property status'
);

select public.test_assert(
    public.property_status_actor_owns('27f00000-0000-0000-0000-000000000002', 'device-a', 'device-a'),
    'different user on the same device should own property status when device ownership is present'
);

select public.test_assert(
    not public.property_status_actor_owns('27f00000-0000-0000-0000-000000000002', 'device-a', 'device-a-other'),
    'different user on a different device should not own property status'
);

select public.test_assert(
    not public.property_status_actor_owns(null, null, 'device-a'),
    'null owner fields should not own property status'
);

select public.set_property_status_pending_export(
    '27f30000-0000-0000-0000-000000000002',
    '27f40000-0000-0000-0000-000000000002',
    'device-a-other',
    'test:same-user-different-device-pending'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '27f30000-0000-0000-0000-000000000002'
          and status = 'pending_export'
          and pending_export_session_id = '27f40000-0000-0000-0000-000000000002'
          and draft_session_id is null
          and owner_user_id is null
          and owner_device_id is null
    ),
    'pending export should clear draft ownership while preserving the pending session id'
);

select public.release_property_status_if_owner(
    '27f30000-0000-0000-0000-000000000002',
    'device-a',
    'test:release-pending-noop'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '27f30000-0000-0000-0000-000000000002'
          and status = 'pending_export'
    ),
    'release_if_owner should not clear pending export state'
);

select public.set_property_status_exported(
    '27f30000-0000-0000-0000-000000000002',
    '27f40000-0000-0000-0000-000000000002',
    'device-a',
    'test:exported'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '27f30000-0000-0000-0000-000000000002'
          and status = 'exported'
          and pending_export_session_id is null
          and draft_session_id is null
          and last_exported_session_id = '27f40000-0000-0000-0000-000000000002'
    ),
    'exported status should clear operational locks and persist last exported session'
);

select public.claim_property_status(
    '27f30000-0000-0000-0000-000000000003',
    '27f40000-0000-0000-0000-000000000003',
    'device-a',
    'test:release-claim'
);

select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000002', true);

select public.test_expect_exception(
    $$select public.release_property_status_if_owner('27f30000-0000-0000-0000-000000000003', 'device-b', 'test:bad-release')$$,
    'non-owner should not release fresh occupied state'
);

select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000001', true);

select public.release_property_status_if_owner(
    '27f30000-0000-0000-0000-000000000003',
    'device-a',
    'test:owner-release'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '27f30000-0000-0000-0000-000000000003'
          and status = 'idle'
          and owner_user_id is null
          and owner_device_id is null
          and active_session_id is null
    ),
    'owner release should clear occupied operational state'
);

select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000003', true);

select public.test_expect_exception(
    $$select public.claim_property_status('27f30000-0000-0000-0000-000000000003', null, 'viewer-device', 'test:viewer-claim')$$,
    'viewer role should not write property_status through RPCs'
);

select set_config('request.jwt.claim.sub', '27f00000-0000-0000-0000-000000000001', true);

select public.rebuild_property_status(
    '27f30000-0000-0000-0000-000000000004',
    'test:rebuild'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '27f30000-0000-0000-0000-000000000004'
          and status = 'draft'
          and draft_session_id = '27f40000-0000-0000-0000-000000000004'
          and owner_user_id = '27f00000-0000-0000-0000-000000000001'
          and owner_device_id = 'device-a'
    ),
    'rebuild should prefer an unresolved material draft over legacy occupancy'
);

reset role;

drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

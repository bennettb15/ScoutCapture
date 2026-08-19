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
    ('28f00000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'slice8-owner@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('28f00000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'slice8-field@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('28f00000-0000-0000-0000-000000000001', 'slice8-owner@example.com', 'Slice 8 Owner', '28f00000-0000-0000-0000-000000000001'),
    ('28f00000-0000-0000-0000-000000000002', 'slice8-field@example.com', 'Slice 8 Field', '28f00000-0000-0000-0000-000000000001')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by, deleted_at)
values ('28f10000-0000-0000-0000-000000000001', 'Property Status Slice 8 Org', 'property-status-slice-8-org', '28f00000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('28f20000-0000-0000-0000-000000000001', '28f10000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000001', 'owner', 'org', '28f00000-0000-0000-0000-000000000001', null),
    ('28f20000-0000-0000-0000-000000000002', '28f10000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000002', 'field', 'org', '28f00000-0000-0000-0000-000000000001', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by, revision, deleted_at, is_archived)
values
    ('28f30000-0000-0000-0000-000000000001', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Stale Occupied Idle', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000002', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Stale Occupied Exported', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000003', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Stale Occupied Pending', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000004', '28f10000-0000-0000-0000-000000000001', 'Slice 8 False Draft Exported', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000005', '28f10000-0000-0000-0000-000000000001', 'Slice 8 False Draft Idle', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000006', '28f10000-0000-0000-0000-000000000001', 'Slice 8 False Pending Idle', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000007', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Valid Draft', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000008', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Valid Pending', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000009', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Fresh Occupied', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000010', '28f10000-0000-0000-0000-000000000001', 'Slice 8 False Draft Pending', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000011', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Retired Shot Draft', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000012', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Hidden Shot Draft', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000013', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Finalish Draft', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000014', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Shot Owner Draft', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000015', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Event Owner Draft', '28f00000-0000-0000-0000-000000000001', 1, null, false),
    ('28f30000-0000-0000-0000-000000000016', '28f10000-0000-0000-0000-000000000001', 'Slice 8 Actor Fallback Draft', '28f00000-0000-0000-0000-000000000001', 1, null, false)
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
    exported_at,
    is_sealed,
    first_delivered_at,
    updated_by,
    locked_by_user_id,
    locked_by_device_id,
    locked_at,
    deleted_at
)
values
    ('28f40000-0000-0000-0000-000000000002', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000002', 'Stale Occupied Exported Session', 'completed', '2026-06-01T10:00:00Z', '2026-06-01T11:00:00Z', null, true, '2026-06-01T12:00:00Z', '28f00000-0000-0000-0000-000000000001', null, null, null, null),
    ('28f40000-0000-0000-0000-000000000003', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000003', 'Stale Occupied Pending Session', 'completed', '2026-06-01T10:00:00Z', '2026-06-01T11:00:00Z', null, true, null, '28f00000-0000-0000-0000-000000000001', null, null, null, null),
    ('28f40000-0000-0000-0000-000000000004', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000004', 'False Draft Exported Session', 'completed', '2026-06-01T10:00:00Z', '2026-06-01T11:00:00Z', '2026-06-01T12:00:00Z', true, '2026-06-01T12:00:00Z', '28f00000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000002', 'stale-device', '2026-06-01T10:00:00Z', null),
    ('28f40000-0000-0000-0000-000000000007', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000007', 'Valid Draft Session', 'draft', '2026-06-01T10:00:00Z', null, null, false, null, '28f00000-0000-0000-0000-000000000002', null, null, null, null),
    ('28f40000-0000-0000-0000-000000000008', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000008', 'Valid Pending Session', 'completed', '2026-06-01T10:00:00Z', '2026-06-01T11:00:00Z', null, true, null, '28f00000-0000-0000-0000-000000000001', null, null, null, null),
    ('28f40000-0000-0000-0000-000000000010', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000010', 'False Draft Pending Session', 'completed', '2026-06-01T10:00:00Z', '2026-06-01T11:00:00Z', null, true, null, '28f00000-0000-0000-0000-000000000001', null, null, null, null),
    ('28f40000-0000-0000-0000-000000000011', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000011', 'Retired Shot Draft Session', 'draft', '2026-06-01T10:00:00Z', null, null, false, null, '28f00000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000001', 'device-a', '2026-06-01T10:05:00Z', null),
    ('28f40000-0000-0000-0000-000000000012', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000012', 'Hidden Shot Draft Session', 'draft', '2026-06-01T10:00:00Z', null, null, false, null, '28f00000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000001', 'device-a', '2026-06-01T10:05:00Z', null),
    ('28f40000-0000-0000-0000-000000000013', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000013', 'Finalish Draft Session', 'draft', '2026-06-01T10:00:00Z', '2026-06-01T11:00:00Z', '2026-06-01T12:00:00Z', false, '2026-06-01T12:00:00Z', '28f00000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000001', 'device-a', '2026-06-01T10:05:00Z', null),
    ('28f40000-0000-0000-0000-000000000014', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000014', 'Shot Owner Draft Session', 'draft', '2026-06-01T10:00:00Z', null, null, false, null, '28f00000-0000-0000-0000-000000000002', '28f00000-0000-0000-0000-000000000002', 'device-b', '2026-06-01T10:05:00Z', null),
    ('28f40000-0000-0000-0000-000000000015', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000015', 'Event Owner Draft Session', 'draft', '2026-06-01T10:00:00Z', null, null, false, null, '28f00000-0000-0000-0000-000000000002', '28f00000-0000-0000-0000-000000000002', 'device-b', '2026-06-01T10:05:00Z', null),
    ('28f40000-0000-0000-0000-000000000016', '28f10000-0000-0000-0000-000000000001', '28f30000-0000-0000-0000-000000000016', 'Actor Fallback Draft Session', 'draft', '2026-06-01T10:00:00Z', null, null, false, null, null, null, null, null, null)
on conflict (id) do update
set org_id = excluded.org_id,
    property_id = excluded.property_id,
    title = excluded.title,
    status = excluded.status,
    started_at = excluded.started_at,
    completed_at = excluded.completed_at,
    exported_at = excluded.exported_at,
    is_sealed = excluded.is_sealed,
    first_delivered_at = excluded.first_delivered_at,
    updated_by = excluded.updated_by,
    locked_by_user_id = excluded.locked_by_user_id,
    locked_by_device_id = excluded.locked_by_device_id,
    locked_at = excluded.locked_at,
    deleted_at = excluded.deleted_at;

insert into public.shots (id, org_id, session_id, shot_type, position, updated_by, deleted_at)
values
    ('28f50000-0000-0000-0000-000000000002', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000002', 'overview', 1, '28f00000-0000-0000-0000-000000000001', null),
    ('28f50000-0000-0000-0000-000000000003', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000003', 'overview', 1, '28f00000-0000-0000-0000-000000000001', null),
    ('28f50000-0000-0000-0000-000000000004', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000004', 'overview', 1, '28f00000-0000-0000-0000-000000000001', null),
    ('28f50000-0000-0000-0000-000000000007', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000007', 'overview', 1, '28f00000-0000-0000-0000-000000000002', null),
    ('28f50000-0000-0000-0000-000000000008', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000008', 'overview', 1, '28f00000-0000-0000-0000-000000000001', null),
    ('28f50000-0000-0000-0000-000000000010', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000010', 'overview', 1, '28f00000-0000-0000-0000-000000000001', null),
    ('28f50000-0000-0000-0000-000000000011', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000011', 'overview', 1, '28f00000-0000-0000-0000-000000000001', null),
    ('28f50000-0000-0000-0000-000000000012', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000012', 'overview', 1, '28f00000-0000-0000-0000-000000000001', null),
    ('28f50000-0000-0000-0000-000000000013', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000013', 'overview', 1, '28f00000-0000-0000-0000-000000000001', null),
    ('28f50000-0000-0000-0000-000000000014', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000014', 'overview', 1, '28f00000-0000-0000-0000-000000000001', null),
    ('28f50000-0000-0000-0000-000000000015', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000015', 'overview', 1, null, null),
    ('28f50000-0000-0000-0000-000000000016', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000016', 'overview', 1, null, null)
on conflict (id) do update
set org_id = excluded.org_id,
    session_id = excluded.session_id,
    shot_type = excluded.shot_type,
    position = excluded.position,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

update public.shots
set lifecycle_state = 'retired',
    retired_at = '2026-06-01T10:10:00Z',
    retired_reason = 'accidental capture',
    retired_by = '28f00000-0000-0000-0000-000000000001',
    lifecycle_updated_at = '2026-06-01T10:10:00Z',
    hidden_from_gallery = null,
    storage_bucket = 'scoutcapture-originals',
    storage_path = 'slice8/retired-shot.heic',
    upload_state = 'uploaded',
    byte_size = 100
where id = '28f50000-0000-0000-0000-000000000011';

update public.shots
set lifecycle_state = null,
    hidden_from_gallery = true,
    storage_bucket = 'scoutcapture-originals',
    storage_path = 'slice8/hidden-shot.heic',
    upload_state = 'uploaded',
    byte_size = 100
where id = '28f50000-0000-0000-0000-000000000012';

update public.shots
set lifecycle_state = null,
    hidden_from_gallery = false,
    storage_bucket = 'scoutcapture-originals',
    storage_path = 'slice8/finalish-draft-shot.heic',
    upload_state = 'uploaded',
    byte_size = 100
where id = '28f50000-0000-0000-0000-000000000013';

insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload, created_at)
values
    ('28f60000-0000-0000-0000-000000000015', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000015', '28f30000-0000-0000-0000-000000000015', '28f00000-0000-0000-0000-000000000001', 'session.started', '{}'::jsonb, '2026-06-01T10:01:00Z'),
    ('28f60000-0000-0000-0000-000000000016', '28f10000-0000-0000-0000-000000000001', '28f40000-0000-0000-0000-000000000015', '28f30000-0000-0000-0000-000000000015', '28f00000-0000-0000-0000-000000000002', 'session.locked', '{}'::jsonb, '2026-06-01T10:02:00Z')
on conflict (id) do update
set org_id = excluded.org_id,
    session_id = excluded.session_id,
    property_id = excluded.property_id,
    actor_user_id = excluded.actor_user_id,
    event_type = excluded.event_type,
    payload = excluded.payload,
    created_at = excluded.created_at;

insert into public.property_session_occupancy (
    property_id,
    org_id,
    occupied_by_user_id,
    occupied_by_device_id,
    occupied_at,
    updated_by
)
values
    ('28f30000-0000-0000-0000-000000000001', '28f10000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000002', 'stale-device', timezone('utc', now()) - interval '4 minutes', '28f00000-0000-0000-0000-000000000002'),
    ('28f30000-0000-0000-0000-000000000002', '28f10000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000002', 'stale-device', timezone('utc', now()) - interval '4 minutes', '28f00000-0000-0000-0000-000000000002'),
    ('28f30000-0000-0000-0000-000000000003', '28f10000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000002', 'stale-device', timezone('utc', now()) - interval '4 minutes', '28f00000-0000-0000-0000-000000000002'),
    ('28f30000-0000-0000-0000-000000000009', '28f10000-0000-0000-0000-000000000001', '28f00000-0000-0000-0000-000000000002', 'fresh-device', timezone('utc', now()), '28f00000-0000-0000-0000-000000000002')
on conflict (property_id) do update
set org_id = excluded.org_id,
    occupied_by_user_id = excluded.occupied_by_user_id,
    occupied_by_device_id = excluded.occupied_by_device_id,
    occupied_at = excluded.occupied_at,
    updated_by = excluded.updated_by;

insert into public.property_status (
    property_id,
    org_id,
    status,
    active_session_id,
    draft_session_id,
    pending_export_session_id,
    last_exported_session_id,
    owner_user_id,
    owner_device_id,
    heartbeat_at,
    updated_by,
    status_reason
)
values
    ('28f30000-0000-0000-0000-000000000001', '28f10000-0000-0000-0000-000000000001', 'occupied', null, null, null, null, '28f00000-0000-0000-0000-000000000002', 'stale-device', timezone('utc', now()) - interval '4 minutes', '28f00000-0000-0000-0000-000000000002', 'test:stale-occupied-idle-before'),
    ('28f30000-0000-0000-0000-000000000002', '28f10000-0000-0000-0000-000000000001', 'occupied', null, null, null, null, '28f00000-0000-0000-0000-000000000002', 'stale-device', timezone('utc', now()) - interval '4 minutes', '28f00000-0000-0000-0000-000000000002', 'test:stale-occupied-exported-before'),
    ('28f30000-0000-0000-0000-000000000003', '28f10000-0000-0000-0000-000000000001', 'occupied', null, null, null, null, '28f00000-0000-0000-0000-000000000002', 'stale-device', timezone('utc', now()) - interval '4 minutes', '28f00000-0000-0000-0000-000000000002', 'test:stale-occupied-pending-before'),
    ('28f30000-0000-0000-0000-000000000004', '28f10000-0000-0000-0000-000000000001', 'draft', '28f4ffff-0000-0000-0000-000000000004', '28f4ffff-0000-0000-0000-000000000004', null, null, '28f00000-0000-0000-0000-000000000002', 'other-device', timezone('utc', now()) - interval '1 hour', '28f00000-0000-0000-0000-000000000002', 'test:false-draft-exported-before'),
    ('28f30000-0000-0000-0000-000000000005', '28f10000-0000-0000-0000-000000000001', 'draft', '28f4ffff-0000-0000-0000-000000000005', '28f4ffff-0000-0000-0000-000000000005', null, null, '28f00000-0000-0000-0000-000000000002', 'other-device', timezone('utc', now()) - interval '1 hour', '28f00000-0000-0000-0000-000000000002', 'test:false-draft-idle-before'),
    ('28f30000-0000-0000-0000-000000000006', '28f10000-0000-0000-0000-000000000001', 'pending_export', null, null, '28f4ffff-0000-0000-0000-000000000006', null, null, null, null, '28f00000-0000-0000-0000-000000000002', 'test:false-pending-idle-before'),
    ('28f30000-0000-0000-0000-000000000010', '28f10000-0000-0000-0000-000000000001', 'draft', '28f4ffff-0000-0000-0000-000000000010', '28f4ffff-0000-0000-0000-000000000010', null, null, '28f00000-0000-0000-0000-000000000002', 'other-device', timezone('utc', now()) - interval '1 hour', '28f00000-0000-0000-0000-000000000002', 'test:false-draft-pending-before')
on conflict (property_id) do update
set org_id = excluded.org_id,
    status = excluded.status,
    active_session_id = excluded.active_session_id,
    draft_session_id = excluded.draft_session_id,
    pending_export_session_id = excluded.pending_export_session_id,
    last_exported_session_id = excluded.last_exported_session_id,
    owner_user_id = excluded.owner_user_id,
    owner_device_id = excluded.owner_device_id,
    heartbeat_at = excluded.heartbeat_at,
    updated_by = excluded.updated_by,
    status_reason = excluded.status_reason;

create temp table slice8_history_counts_before as
select
    (select count(*) from public.properties where org_id = '28f10000-0000-0000-0000-000000000001') as properties_count,
    (select count(*) from public.sessions where org_id = '28f10000-0000-0000-0000-000000000001') as sessions_count,
    (select count(*) from public.shots where org_id = '28f10000-0000-0000-0000-000000000001') as shots_count,
    (select count(*) from public.observations where org_id = '28f10000-0000-0000-0000-000000000001') as observations_count,
    (select count(*) from public.session_events where org_id = '28f10000-0000-0000-0000-000000000001') as session_events_count;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', '28f00000-0000-0000-0000-000000000001', true);

select public.rebuild_property_status('28f30000-0000-0000-0000-000000000001', 'test:slice8-stale-occupied-idle');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000002', 'test:slice8-stale-occupied-exported');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000003', 'test:slice8-stale-occupied-pending');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000004', 'test:slice8-false-draft-exported');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000005', 'test:slice8-false-draft-idle');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000006', 'test:slice8-false-pending-idle');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000007', 'test:slice8-valid-draft');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000008', 'test:slice8-valid-pending');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000009', 'test:slice8-fresh-occupied');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000010', 'test:slice8-false-draft-pending');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000011', 'test:slice8-retired-shot-draft');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000012', 'test:slice8-hidden-shot-draft');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000013', 'test:slice8-finalish-draft');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000014', 'test:slice8-shot-owner-draft');
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000015', 'test:slice8-event-owner-draft');

select set_config('request.jwt.claim.sub', '28f00000-0000-0000-0000-000000000002', true);
select public.rebuild_property_status('28f30000-0000-0000-0000-000000000016', 'test:slice8-actor-fallback-draft');

reset role;

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000001'
          and status = 'idle'
          and active_session_id is null
          and draft_session_id is null
          and pending_export_session_id is null
          and last_exported_session_id is null
          and owner_user_id is null
          and owner_device_id is null
          and heartbeat_at is null
    ),
    'stale occupied with no session truth should rebuild to idle and clear operational fields'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000002'
          and status = 'exported'
          and last_exported_session_id = '28f40000-0000-0000-0000-000000000002'
          and owner_user_id is null
          and owner_device_id is null
          and heartbeat_at is null
          and draft_session_id is null
          and pending_export_session_id is null
    ),
    'stale occupied with delivered history should rebuild to exported'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000003'
          and status = 'pending_export'
          and pending_export_session_id = '28f40000-0000-0000-0000-000000000003'
          and owner_user_id is null
          and owner_device_id is null
          and heartbeat_at is null
          and draft_session_id is null
          and last_exported_session_id is null
    ),
    'stale occupied with sealed undelivered history should rebuild to pending export'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000004'
          and status = 'exported'
          and last_exported_session_id = '28f40000-0000-0000-0000-000000000004'
          and draft_session_id is null
          and owner_user_id is null
          and owner_device_id is null
    ),
    'false draft status should not block rebuild to exported'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000005'
          and status = 'idle'
          and draft_session_id is null
          and owner_user_id is null
          and owner_device_id is null
          and heartbeat_at is null
    ),
    'false draft status should not block rebuild to idle'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000006'
          and status = 'idle'
          and pending_export_session_id is null
    ),
    'false pending export status should rebuild away when no pending session exists'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000010'
          and status = 'pending_export'
          and pending_export_session_id = '28f40000-0000-0000-0000-000000000010'
          and draft_session_id is null
          and owner_user_id is null
          and owner_device_id is null
          and heartbeat_at is null
    ),
    'false draft status should not block rebuild to pending export'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000011'
          and status = 'idle'
          and draft_session_id is null
          and owner_user_id is null
          and owner_device_id is null
          and heartbeat_at is null
    ),
    'retired accidental-capture shot should not make a material draft'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000012'
          and status = 'idle'
          and draft_session_id is null
          and owner_user_id is null
          and owner_device_id is null
          and heartbeat_at is null
    ),
    'hidden_from_gallery shot should not make a material draft'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000013'
          and status = 'exported'
          and last_exported_session_id = '28f40000-0000-0000-0000-000000000013'
          and draft_session_id is null
          and owner_user_id is null
          and owner_device_id is null
    ),
    'final-ish draft session should not make a material draft'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000007'
          and status = 'draft'
          and active_session_id = '28f40000-0000-0000-0000-000000000007'
          and draft_session_id = '28f40000-0000-0000-0000-000000000007'
          and owner_user_id = '28f00000-0000-0000-0000-000000000002'
          and owner_device_id is null
          and pending_export_session_id is null
    ),
    'valid material draft should rebuild as draft with conservative updated_by owner fallback'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000014'
          and status = 'draft'
          and draft_session_id = '28f40000-0000-0000-0000-000000000014'
          and owner_user_id = '28f00000-0000-0000-0000-000000000001'
          and owner_device_id is null
    ),
    'rebuild should derive material draft owner from earliest usable shot provenance before stale session lock'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000015'
          and status = 'draft'
          and draft_session_id = '28f40000-0000-0000-0000-000000000015'
          and owner_user_id = '28f00000-0000-0000-0000-000000000001'
          and owner_device_id is null
    ),
    'rebuild should derive material draft owner from earliest session started/locked event when shots have no owner'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000016'
          and status = 'draft'
          and draft_session_id = '28f40000-0000-0000-0000-000000000016'
          and owner_user_id = '28f00000-0000-0000-0000-000000000002'
          and owner_device_id is null
    ),
    'rebuild should fall back to current actor only when material draft has no durable owner provenance'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000008'
          and status = 'pending_export'
          and pending_export_session_id = '28f40000-0000-0000-0000-000000000008'
          and owner_user_id is null
          and owner_device_id is null
    ),
    'valid pending export should remain pending export'
);

select public.test_assert(
    exists (
        select 1
        from public.property_status
        where property_id = '28f30000-0000-0000-0000-000000000009'
          and status = 'occupied'
          and owner_user_id = '28f00000-0000-0000-0000-000000000002'
          and owner_device_id = 'fresh-device'
          and heartbeat_at is not null
          and draft_session_id is null
          and pending_export_session_id is null
          and last_exported_session_id is null
    ),
    'fresh occupied state should remain occupied'
);

select public.test_assert(
    exists (
        select 1
        from slice8_history_counts_before before_counts
        where before_counts.properties_count = (select count(*) from public.properties where org_id = '28f10000-0000-0000-0000-000000000001')
          and before_counts.sessions_count = (select count(*) from public.sessions where org_id = '28f10000-0000-0000-0000-000000000001')
          and before_counts.shots_count = (select count(*) from public.shots where org_id = '28f10000-0000-0000-0000-000000000001')
          and before_counts.observations_count = (select count(*) from public.observations where org_id = '28f10000-0000-0000-0000-000000000001')
          and before_counts.session_events_count = (select count(*) from public.session_events where org_id = '28f10000-0000-0000-0000-000000000001')
    ),
    'rebuild should not modify historical property/session/shot/observation/session_event row counts'
);

drop table slice8_history_counts_before;
drop function public.test_assert(boolean, text);

rollback;

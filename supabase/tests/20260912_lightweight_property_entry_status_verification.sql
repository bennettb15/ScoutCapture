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
    ('91200000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'entry-a@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('91200000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'entry-b@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('91200000-0000-0000-0000-000000000001', 'entry-a@example.com', 'Entry A', '91200000-0000-0000-0000-000000000001'),
    ('91200000-0000-0000-0000-000000000002', 'entry-b@example.com', 'Entry B', '91200000-0000-0000-0000-000000000002')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by, deleted_at)
values ('91210000-0000-0000-0000-000000000001', 'Entry Gate Org', 'entry-gate-org', '91200000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('91220000-0000-0000-0000-000000000001', '91210000-0000-0000-0000-000000000001', '91200000-0000-0000-0000-000000000001', 'field', 'org', '91200000-0000-0000-0000-000000000001', null),
    ('91220000-0000-0000-0000-000000000002', '91210000-0000-0000-0000-000000000001', '91200000-0000-0000-0000-000000000002', 'field', 'org', '91200000-0000-0000-0000-000000000001', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by, revision, deleted_at, is_archived)
values
    ('91230000-0000-0000-0000-000000000001', '91210000-0000-0000-0000-000000000001', 'Entry Idle', '91200000-0000-0000-0000-000000000001', 1, null, false),
    ('91230000-0000-0000-0000-000000000002', '91210000-0000-0000-0000-000000000001', 'Entry Exported', '91200000-0000-0000-0000-000000000001', 1, null, false),
    ('91230000-0000-0000-0000-000000000003', '91210000-0000-0000-0000-000000000001', 'Entry Current Draft', '91200000-0000-0000-0000-000000000001', 1, null, false),
    ('91230000-0000-0000-0000-000000000004', '91210000-0000-0000-0000-000000000001', 'Entry Other Draft', '91200000-0000-0000-0000-000000000001', 1, null, false),
    ('91230000-0000-0000-0000-000000000005', '91210000-0000-0000-0000-000000000001', 'Entry Fresh Occupied', '91200000-0000-0000-0000-000000000001', 1, null, false),
    ('91230000-0000-0000-0000-000000000006', '91210000-0000-0000-0000-000000000001', 'Entry Stale Occupied', '91200000-0000-0000-0000-000000000001', 1, null, false),
    ('91230000-0000-0000-0000-000000000007', '91210000-0000-0000-0000-000000000001', 'Entry Pending Export', '91200000-0000-0000-0000-000000000001', 1, null, false),
    ('91230000-0000-0000-0000-000000000008', '91210000-0000-0000-0000-000000000001', 'Entry Missing Status', '91200000-0000-0000-0000-000000000001', 1, null, false),
    ('91230000-0000-0000-0000-000000000009', '91210000-0000-0000-0000-000000000001', 'Entry Race Claim', '91200000-0000-0000-0000-000000000001', 1, null, false),
    ('91230000-0000-0000-0000-000000000010', '91210000-0000-0000-0000-000000000001', 'Entry Null Session Fallback', '91200000-0000-0000-0000-000000000001', 1, null, false)
on conflict (id) do update
set org_id = excluded.org_id,
    name = excluded.name,
    updated_by = excluded.updated_by,
    revision = excluded.revision,
    deleted_at = excluded.deleted_at,
    is_archived = excluded.is_archived;

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
    ('91230000-0000-0000-0000-000000000001', '91210000-0000-0000-0000-000000000001', 'idle', null, null, null, null, null, null, null, '91200000-0000-0000-0000-000000000001', 'test:idle'),
    ('91230000-0000-0000-0000-000000000002', '91210000-0000-0000-0000-000000000001', 'exported', null, null, null, '91240000-0000-0000-0000-000000000002', null, null, null, '91200000-0000-0000-0000-000000000001', 'test:exported'),
    ('91230000-0000-0000-0000-000000000003', '91210000-0000-0000-0000-000000000001', 'draft', '91240000-0000-0000-0000-000000000003', '91240000-0000-0000-0000-000000000003', null, null, '91200000-0000-0000-0000-000000000001', 'device-a', timezone('utc', now()), '91200000-0000-0000-0000-000000000001', 'test:current-draft'),
    ('91230000-0000-0000-0000-000000000004', '91210000-0000-0000-0000-000000000001', 'draft', '91240000-0000-0000-0000-000000000004', '91240000-0000-0000-0000-000000000004', null, null, '91200000-0000-0000-0000-000000000002', 'device-b', timezone('utc', now()), '91200000-0000-0000-0000-000000000002', 'test:other-draft'),
    ('91230000-0000-0000-0000-000000000005', '91210000-0000-0000-0000-000000000001', 'occupied', '91240000-0000-0000-0000-000000000005', null, null, null, '91200000-0000-0000-0000-000000000002', 'device-b', timezone('utc', now()), '91200000-0000-0000-0000-000000000002', 'test:fresh-occupied'),
    ('91230000-0000-0000-0000-000000000006', '91210000-0000-0000-0000-000000000001', 'occupied', '91240000-0000-0000-0000-000000000006', null, null, null, '91200000-0000-0000-0000-000000000002', 'device-b', timezone('utc', now()) - interval '4 minutes', '91200000-0000-0000-0000-000000000002', 'test:stale-occupied'),
    ('91230000-0000-0000-0000-000000000007', '91210000-0000-0000-0000-000000000001', 'pending_export', null, null, '91240000-0000-0000-0000-000000000007', null, '91200000-0000-0000-0000-000000000002', 'device-b', timezone('utc', now()), '91200000-0000-0000-0000-000000000002', 'test:pending-export'),
    ('91230000-0000-0000-0000-000000000009', '91210000-0000-0000-0000-000000000001', 'idle', null, null, null, null, null, null, null, '91200000-0000-0000-0000-000000000001', 'test:race-idle'),
    ('91230000-0000-0000-0000-000000000010', '91210000-0000-0000-0000-000000000001', 'idle', null, null, null, null, null, null, null, '91200000-0000-0000-0000-000000000001', 'test:null-session')
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

select set_config('request.jwt.claim.sub', '91200000-0000-0000-0000-000000000001', true);

select public.test_assert(
    (
        select entry_state = 'unlocked_and_claimed'
           and lock_session_id = '9124aaaa-0000-0000-0000-000000000001'
           and locked_by_user_id = '91200000-0000-0000-0000-000000000001'
           and locked_by_device_id = 'device-a'
           and requires_fallback = false
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000001',
            'device-a',
            '9124aaaa-0000-0000-0000-000000000001'
        )
    ),
    'idle property should be atomically claimed'
);

select public.test_assert(
    (
        select status = 'occupied'
           and active_session_id = '9124aaaa-0000-0000-0000-000000000001'
           and owner_user_id = '91200000-0000-0000-0000-000000000001'
        from public.property_status
        where property_id = '91230000-0000-0000-0000-000000000001'
    ),
    'idle claim should update property_status occupancy'
);

select public.test_assert(
    (
        select entry_state = 'unlocked_and_claimed'
           and reason = 'claimed_from_exported'
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000002',
            'device-a',
            '9124aaaa-0000-0000-0000-000000000002'
        )
    ),
    'exported property should be atomically claimed'
);

select public.test_assert(
    (
        select entry_state = 'locked_by_current_user'
           and lock_session_id = '91240000-0000-0000-0000-000000000003'
           and locked_by_email = 'entry-a@example.com'
           and requires_fallback = false
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000003',
            'device-a',
            '9124aaaa-0000-0000-0000-000000000003'
        )
    ),
    'current-user draft should return locked_by_current_user'
);

select public.test_assert(
    (
        select entry_state = 'locked_by_other_user'
           and lock_session_id = '91240000-0000-0000-0000-000000000004'
           and locked_by_email = 'entry-b@example.com'
           and requires_fallback = false
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000004',
            'device-a',
            '9124aaaa-0000-0000-0000-000000000004'
        )
    ),
    'other-user draft should return locked_by_other_user'
);

select public.test_assert(
    (
        select entry_state = 'locked_by_other_user'
           and reason = 'other_user_occupied'
           and requires_fallback = false
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000005',
            'device-a',
            '9124aaaa-0000-0000-0000-000000000005'
        )
    ),
    'fresh other-user occupied property should stay locked'
);

select public.test_assert(
    (
        select entry_state = 'stale_claimable'
           and reason = 'occupied_stale_claimable'
           and lock_age_seconds >= 180
           and requires_fallback = false
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000006',
            'device-a',
            '9124aaaa-0000-0000-0000-000000000006'
        )
    ),
    'stale occupied property should return stale_claimable'
);

select public.test_assert(
    (
        select entry_state = 'pending_export'
           and lock_session_id = '91240000-0000-0000-0000-000000000007'
           and requires_fallback = false
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000007',
            'device-a',
            '9124aaaa-0000-0000-0000-000000000007'
        )
    ),
    'pending export should remain conservative'
);

select public.test_assert(
    (
        select entry_state = 'unknown_requires_fallback'
           and requires_fallback = true
           and reason = 'missing_property_status_row'
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000008',
            'device-a',
            '9124aaaa-0000-0000-0000-000000000008'
        )
    ),
    'missing property_status row should require fallback'
);

select public.test_assert(
    (
        select entry_state = 'unknown_requires_fallback'
           and requires_fallback = true
           and reason = 'claim_requires_session_id'
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000010',
            'device-a',
            null
        )
    ),
    'claimable property without session id should require fallback'
);

select public.test_assert(
    (
        select entry_state = 'unlocked_and_claimed'
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000009',
            'device-a',
            '9124aaaa-0000-0000-0000-000000000009'
        )
    ),
    'first sequential race claim should claim'
);

select set_config('request.jwt.claim.sub', '91200000-0000-0000-0000-000000000002', true);

select public.test_assert(
    (
        select entry_state = 'locked_by_other_user'
           and lock_session_id = '9124aaaa-0000-0000-0000-000000000009'
           and locked_by_user_id = '91200000-0000-0000-0000-000000000001'
           and requires_fallback = false
        from public.get_or_claim_property_entry_status(
            '91230000-0000-0000-0000-000000000009',
            'device-b',
            '9124bbbb-0000-0000-0000-000000000009'
        )
    ),
    'second sequential race claim should see other-user lock'
);

rollback;

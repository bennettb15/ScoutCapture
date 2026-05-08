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

create or replace function public.test_session_soft_delete_state(target_session_id uuid)
returns table (
    id uuid,
    org_id uuid,
    property_id uuid,
    status text,
    started_at timestamptz,
    ended_at timestamptz,
    exported_at timestamptz,
    is_sealed boolean,
    first_delivered_at timestamptz,
    re_export_expires_at timestamptz,
    notes text,
    deleted_at timestamptz,
    updated_by uuid,
    updated_at timestamptz,
    revision bigint
)
language sql
security definer
set search_path = public
as $$
    select session_row.id,
           session_row.org_id,
           session_row.property_id,
           session_row.status,
           session_row.started_at,
           session_row.completed_at as ended_at,
           session_row.exported_at,
           session_row.is_sealed,
           session_row.first_delivered_at,
           session_row.re_export_expires_at,
           session_row.notes,
           session_row.deleted_at,
           session_row.updated_by,
           session_row.updated_at,
           session_row.revision
    from public.sessions session_row
    where session_row.id = target_session_id;
$$;

create or replace function public.test_session_related_row_counts(target_session_id uuid)
returns table (
    shots_count bigint,
    observations_count bigint,
    events_count bigint
)
language sql
security definer
set search_path = public
as $$
    select
        (select count(*) from public.shots shot where shot.session_id = target_session_id) as shots_count,
        (select count(*) from public.observations observation_row where observation_row.session_id = target_session_id) as observations_count,
        (select count(*) from public.session_events event_row where event_row.session_id = target_session_id) as events_count;
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
    ('14b20000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner-14b2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('14b20000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'manager-14b2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('14b20000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'field-14b2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now())),
    ('14b20000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'viewer-14b2@example.com', '', timezone('utc', now()), '', '', '', '', '{"provider":"email","providers":["email"]}', '{}'::jsonb, timezone('utc', now()), timezone('utc', now()))
on conflict (id) do nothing;

insert into public.users_profile (id, email, full_name, updated_by)
values
    ('14b20000-0000-0000-0000-000000000001', 'owner-14b2@example.com', 'Owner 14B2', '14b20000-0000-0000-0000-000000000001'),
    ('14b20000-0000-0000-0000-000000000002', 'manager-14b2@example.com', 'Manager 14B2', '14b20000-0000-0000-0000-000000000002'),
    ('14b20000-0000-0000-0000-000000000003', 'field-14b2@example.com', 'Field 14B2', '14b20000-0000-0000-0000-000000000003'),
    ('14b20000-0000-0000-0000-000000000004', 'viewer-14b2@example.com', 'Viewer 14B2', '14b20000-0000-0000-0000-000000000004')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    updated_by = excluded.updated_by;

insert into public.orgs (id, name, slug, updated_by, deleted_at)
values ('14b21000-0000-0000-0000-000000000001', 'Session Soft Delete Org', 'session-soft-delete-org', '14b20000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.org_memberships (id, org_id, user_id, role, access_scope, updated_by, deleted_at)
values
    ('14b22000-0000-0000-0000-000000000001', '14b21000-0000-0000-0000-000000000001', '14b20000-0000-0000-0000-000000000001', 'owner', 'org', '14b20000-0000-0000-0000-000000000001', null),
    ('14b22000-0000-0000-0000-000000000002', '14b21000-0000-0000-0000-000000000001', '14b20000-0000-0000-0000-000000000002', 'manager', 'org', '14b20000-0000-0000-0000-000000000001', null),
    ('14b22000-0000-0000-0000-000000000003', '14b21000-0000-0000-0000-000000000001', '14b20000-0000-0000-0000-000000000003', 'field', 'org', '14b20000-0000-0000-0000-000000000001', null),
    ('14b22000-0000-0000-0000-000000000004', '14b21000-0000-0000-0000-000000000001', '14b20000-0000-0000-0000-000000000004', 'viewer', 'org', '14b20000-0000-0000-0000-000000000001', null)
on conflict (org_id, user_id) do update
set role = excluded.role,
    access_scope = excluded.access_scope,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.properties (id, org_id, name, updated_by, deleted_at)
values
    ('14b23000-0000-0000-0000-000000000001', '14b21000-0000-0000-0000-000000000001', 'Session Soft Delete Property', '14b20000-0000-0000-0000-000000000001', null),
    ('14b23000-0000-0000-0000-000000000002', '14b21000-0000-0000-0000-000000000001', 'Filtered Session Property', '14b20000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set org_id = excluded.org_id,
    name = excluded.name,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

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
    re_export_expires_at,
    notes,
    updated_at,
    updated_by,
    revision,
    deleted_at
)
values
    ('14b24000-0000-0000-0000-000000000001', '14b21000-0000-0000-0000-000000000001', '14b23000-0000-0000-0000-000000000001', 'Owner Delete', 'completed', '2026-01-01T10:00:00Z', '2026-01-01T11:00:00Z', '2026-01-01T12:00:00Z', true, '2026-01-01T12:00:00Z', '2026-01-08T12:00:00Z', 'owner notes', '2026-01-01T00:00:00Z', '14b20000-0000-0000-0000-000000000001', 10, null),
    ('14b24000-0000-0000-0000-000000000002', '14b21000-0000-0000-0000-000000000001', '14b23000-0000-0000-0000-000000000001', 'Manager Delete', 'draft', '2026-01-02T10:00:00Z', null, null, false, null, null, 'manager notes', '2026-01-01T00:00:00Z', '14b20000-0000-0000-0000-000000000001', 20, null),
    ('14b24000-0000-0000-0000-000000000003', '14b21000-0000-0000-0000-000000000001', '14b23000-0000-0000-0000-000000000001', 'Field Target', 'draft', '2026-01-03T10:00:00Z', null, null, false, null, null, 'field target', '2026-01-01T00:00:00Z', '14b20000-0000-0000-0000-000000000001', 30, null),
    ('14b24000-0000-0000-0000-000000000004', '14b21000-0000-0000-0000-000000000001', '14b23000-0000-0000-0000-000000000001', 'Viewer Target', 'draft', '2026-01-04T10:00:00Z', null, null, false, null, null, 'viewer target', '2026-01-01T00:00:00Z', '14b20000-0000-0000-0000-000000000001', 40, null),
    ('14b24000-0000-0000-0000-000000000005', '14b21000-0000-0000-0000-000000000001', '14b23000-0000-0000-0000-000000000001', 'Owner Restore', 'completed', '2026-01-05T10:00:00Z', '2026-01-05T11:00:00Z', '2026-01-05T12:00:00Z', true, '2026-01-05T12:00:00Z', '2026-01-12T12:00:00Z', 'preserve me', '2026-01-01T00:00:00Z', '14b20000-0000-0000-0000-000000000001', 50, '2026-01-06T00:00:00Z'),
    ('14b24000-0000-0000-0000-000000000006', '14b21000-0000-0000-0000-000000000001', '14b23000-0000-0000-0000-000000000002', 'Manager Restore Filtered', 'completed', '2026-01-06T10:00:00Z', '2026-01-06T11:00:00Z', '2026-01-06T12:00:00Z', true, '2026-01-06T12:00:00Z', '2026-01-13T12:00:00Z', 'manager restore', '2026-01-01T00:00:00Z', '14b20000-0000-0000-0000-000000000001', 60, '2026-01-07T00:00:00Z')
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
    re_export_expires_at = excluded.re_export_expires_at,
    notes = excluded.notes,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by,
    revision = excluded.revision,
    deleted_at = excluded.deleted_at;

insert into public.shots (id, org_id, session_id, shot_type, position, updated_by, deleted_at)
values ('14b25000-0000-0000-0000-000000000001', '14b21000-0000-0000-0000-000000000001', '14b24000-0000-0000-0000-000000000001', 'overview', 1, '14b20000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set org_id = excluded.org_id,
    session_id = excluded.session_id,
    shot_type = excluded.shot_type,
    position = excluded.position,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.observations (id, org_id, session_id, shot_id, category, status, title, updated_by, deleted_at)
values ('14b26000-0000-0000-0000-000000000001', '14b21000-0000-0000-0000-000000000001', '14b24000-0000-0000-0000-000000000001', '14b25000-0000-0000-0000-000000000001', 'note', 'active', 'Observation', '14b20000-0000-0000-0000-000000000001', null)
on conflict (id) do update
set org_id = excluded.org_id,
    session_id = excluded.session_id,
    shot_id = excluded.shot_id,
    category = excluded.category,
    status = excluded.status,
    title = excluded.title,
    updated_by = excluded.updated_by,
    deleted_at = excluded.deleted_at;

insert into public.session_events (id, org_id, session_id, property_id, actor_user_id, event_type, payload)
values ('14b27000-0000-0000-0000-000000000001', '14b21000-0000-0000-0000-000000000001', '14b24000-0000-0000-0000-000000000001', '14b23000-0000-0000-0000-000000000001', '14b20000-0000-0000-0000-000000000001', 'session.seeded', '{}'::jsonb)
on conflict (id) do nothing;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);

select set_config('request.jwt.claim.sub', '14b20000-0000-0000-0000-000000000001', true);
select public.soft_delete_session('14b24000-0000-0000-0000-000000000001');
select public.test_assert(
    exists (
        select 1
        from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000001')
        where deleted_at is not null
          and updated_by = '14b20000-0000-0000-0000-000000000001'
          and revision = 11
          and updated_at <> '2026-01-01T00:00:00Z'::timestamptz
    ),
    'owner soft delete should set deleted_at, updated_by, updated_at, and revision'
);

create temp table test_soft_delete_idempotency_snapshot as
select updated_at,
       updated_by,
       revision
from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000001');

select set_config('request.jwt.claim.sub', '14b20000-0000-0000-0000-000000000002', true);
select public.soft_delete_session('14b24000-0000-0000-0000-000000000001');
select public.test_assert(
    exists (
        select 1
        from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000001') current_state
        cross join test_soft_delete_idempotency_snapshot snapshot
        where current_state.updated_at = snapshot.updated_at
          and current_state.updated_by = snapshot.updated_by
          and current_state.revision = snapshot.revision
    ),
    'soft delete should be idempotent and not update updated_at, updated_by, or revision when already deleted'
);

select set_config('request.jwt.claim.sub', '14b20000-0000-0000-0000-000000000001', true);
select public.test_assert(
    not exists (
        select 1
        from public.sessions
        where id = '14b24000-0000-0000-0000-000000000001'
    ),
    'normal sessions SELECT should hide deleted session'
);
select public.test_assert(
    exists (
        select 1
        from public.fetch_recently_deleted_sessions('14b21000-0000-0000-0000-000000000001')
        where id = '14b24000-0000-0000-0000-000000000001'
          and org_id = '14b21000-0000-0000-0000-000000000001'
          and property_id = '14b23000-0000-0000-0000-000000000001'
          and ended_at = '2026-01-01T11:00:00Z'::timestamptz
          and revision = 11
    ),
    'owner should fetch recently deleted session through RPC'
);

select public.restore_session('14b24000-0000-0000-0000-000000000005');
select public.test_assert(
    exists (
        select 1
        from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000005')
        where deleted_at is null
          and updated_by = '14b20000-0000-0000-0000-000000000001'
          and revision = 51
          and status = 'completed'
          and ended_at = '2026-01-05T11:00:00Z'::timestamptz
          and exported_at = '2026-01-05T12:00:00Z'::timestamptz
          and is_sealed = true
          and first_delivered_at = '2026-01-05T12:00:00Z'::timestamptz
          and re_export_expires_at = '2026-01-12T12:00:00Z'::timestamptz
          and notes = 'preserve me'
    ),
    'owner restore should preserve lifecycle/export/delivery fields'
);

create temp table test_restore_idempotency_snapshot as
select updated_at,
       updated_by,
       revision
from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000005');

select set_config('request.jwt.claim.sub', '14b20000-0000-0000-0000-000000000002', true);
select public.restore_session('14b24000-0000-0000-0000-000000000005');
select public.test_assert(
    exists (
        select 1
        from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000005') current_state
        cross join test_restore_idempotency_snapshot snapshot
        where current_state.updated_at = snapshot.updated_at
          and current_state.updated_by = snapshot.updated_by
          and current_state.revision = snapshot.revision
    ),
    'restore should be idempotent and not update updated_at, updated_by, or revision when already restored'
);

select set_config('request.jwt.claim.sub', '14b20000-0000-0000-0000-000000000002', true);
select public.soft_delete_session('14b24000-0000-0000-0000-000000000002');
select public.test_assert(
    exists (
        select 1
        from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000002')
        where deleted_at is not null
          and updated_by = '14b20000-0000-0000-0000-000000000002'
          and revision = 21
    ),
    'manager should soft delete session'
);
select public.test_assert(
    exists (
        select 1
        from public.fetch_recently_deleted_sessions(
            '14b21000-0000-0000-0000-000000000001',
            '14b23000-0000-0000-0000-000000000002'
        )
        where id = '14b24000-0000-0000-0000-000000000006'
          and property_id = '14b23000-0000-0000-0000-000000000002'
    ),
    'fetch recently deleted sessions should support property filter'
);
select public.restore_session('14b24000-0000-0000-0000-000000000006');
select public.test_assert(
    exists (
        select 1
        from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000006')
        where deleted_at is null
          and updated_by = '14b20000-0000-0000-0000-000000000002'
          and revision = 61
    ),
    'manager should restore session'
);

select set_config('request.jwt.claim.sub', '14b20000-0000-0000-0000-000000000003', true);
select public.test_expect_exception(
    $$select public.soft_delete_session('14b24000-0000-0000-0000-000000000003')$$,
    'field must not soft delete session'
);
select public.test_expect_exception(
    $$select public.restore_session('14b24000-0000-0000-0000-000000000001')$$,
    'field must not restore session'
);
select public.test_expect_exception(
    $$select count(*) from public.fetch_recently_deleted_sessions('14b21000-0000-0000-0000-000000000001')$$,
    'field must not fetch recently deleted sessions'
);

select set_config('request.jwt.claim.sub', '14b20000-0000-0000-0000-000000000004', true);
select public.test_expect_exception(
    $$select public.soft_delete_session('14b24000-0000-0000-0000-000000000004')$$,
    'viewer must not soft delete session'
);
select public.test_expect_exception(
    $$select public.restore_session('14b24000-0000-0000-0000-000000000001')$$,
    'viewer must not restore session'
);
select public.test_expect_exception(
    $$select count(*) from public.fetch_recently_deleted_sessions('14b21000-0000-0000-0000-000000000001')$$,
    'viewer must not fetch recently deleted sessions'
);

select public.test_assert(
    exists (
        select 1
        from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000003')
        where deleted_at is null
          and revision = 30
    ),
    'field-blocked soft delete should leave target unchanged'
);
select public.test_assert(
    exists (
        select 1
        from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000004')
        where deleted_at is null
          and revision = 40
    ),
    'viewer-blocked soft delete should leave target unchanged'
);

select public.test_assert(
    (select count(*) from public.test_session_soft_delete_state('14b24000-0000-0000-0000-000000000001')) = 1,
    'soft delete and restore contract must not hard delete session rows'
);
select public.test_assert(
    (
        select shots_count
        from public.test_session_related_row_counts('14b24000-0000-0000-0000-000000000001')
    ) = 1,
    'soft delete must not hard delete shots'
);
select public.test_assert(
    (
        select observations_count
        from public.test_session_related_row_counts('14b24000-0000-0000-0000-000000000001')
    ) = 1,
    'soft delete must not hard delete observations'
);
select public.test_assert(
    (
        select events_count
        from public.test_session_related_row_counts('14b24000-0000-0000-0000-000000000001')
    ) = 1,
    'soft delete must not hard delete session events'
);

reset role;

drop function public.test_session_related_row_counts(uuid);
drop function public.test_session_soft_delete_state(uuid);
drop function public.test_expect_exception(text, text);
drop function public.test_assert(boolean, text);

rollback;

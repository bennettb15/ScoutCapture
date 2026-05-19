insert into storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
)
values (
    'scoutcapture-session-snapshots',
    'scoutcapture-session-snapshots',
    false,
    null,
    array['application/json']
)
on conflict (id) do update
set public = false,
    allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.session_snapshots (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    property_id uuid not null references public.properties(id),
    session_id uuid not null references public.sessions(id),
    snapshot_kind text not null,
    snapshot_schema_version integer not null,
    session_metadata_schema_version integer,
    trigger text not null,
    session_status text,
    is_sealed boolean not null default false,
    exported_at timestamptz,
    first_delivered_at timestamptz,
    re_export_expires_at timestamptz,
    payload_storage_bucket text not null,
    payload_storage_path text not null,
    payload_byte_size bigint not null,
    raw_session_json_sha256 text not null,
    snapshot_payload_sha256 text not null,
    manifest jsonb not null default '{}'::jsonb,
    shot_count integer not null default 0,
    issue_count integer not null default 0,
    guided_count integer not null default 0,
    media_manifest_count integer not null default 0,
    missing_local_originals_count integer not null default 0,
    supabase_storage_metadata_count integer not null default 0,
    supersedes_snapshot_id uuid references public.session_snapshots(id),
    superseded_by_snapshot_id uuid references public.session_snapshots(id),
    superseded_at timestamptz,
    created_at timestamptz not null default timezone('utc', now()),
    created_by uuid references public.users_profile(id),
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid references public.users_profile(id),
    revision bigint not null default 1,
    deleted_at timestamptz
);

alter table public.session_snapshots
    drop constraint if exists session_snapshots_snapshot_kind_check;
alter table public.session_snapshots
    add constraint session_snapshots_snapshot_kind_check
    check (snapshot_kind in ('draft', 'completed', 'export', 'delivery', 'manual'));

alter table public.session_snapshots
    drop constraint if exists session_snapshots_payload_bucket_check;
alter table public.session_snapshots
    add constraint session_snapshots_payload_bucket_check
    check (payload_storage_bucket = 'scoutcapture-session-snapshots');

alter table public.session_snapshots
    drop constraint if exists session_snapshots_payload_byte_size_check;
alter table public.session_snapshots
    add constraint session_snapshots_payload_byte_size_check
    check (payload_byte_size > 0);

alter table public.session_snapshots
    drop constraint if exists session_snapshots_counts_check;
alter table public.session_snapshots
    add constraint session_snapshots_counts_check
    check (
        shot_count >= 0
        and issue_count >= 0
        and guided_count >= 0
        and media_manifest_count >= 0
        and missing_local_originals_count >= 0
        and supabase_storage_metadata_count >= 0
    );

alter table public.session_snapshots
    drop constraint if exists session_snapshots_sha256_check;
alter table public.session_snapshots
    add constraint session_snapshots_sha256_check
    check (
        raw_session_json_sha256 ~ '^[0-9a-f]{64}$'
        and snapshot_payload_sha256 ~ '^[0-9a-f]{64}$'
    );

create or replace function public.session_snapshot_row_matches_parents(
    target_org_id uuid,
    target_property_id uuid,
    target_session_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select public.property_belongs_to_org(target_property_id, target_org_id)
        and exists (
            select 1
            from public.sessions session_row
            where session_row.id = target_session_id
              and session_row.org_id = target_org_id
              and session_row.property_id = target_property_id
              and session_row.deleted_at is null
        );
$$;

alter table public.session_snapshots
    drop constraint if exists session_snapshots_parent_match_check;
alter table public.session_snapshots
    add constraint session_snapshots_parent_match_check
    check (public.session_snapshot_row_matches_parents(org_id, property_id, session_id));

create or replace function public.session_snapshot_expected_storage_path(
    target_org_id uuid,
    target_property_id uuid,
    target_session_id uuid,
    target_snapshot_kind text,
    target_snapshot_id uuid
)
returns text
language sql
immutable
as $$
    select 'orgs/' || lower(target_org_id::text)
        || '/properties/' || lower(target_property_id::text)
        || '/sessions/' || lower(target_session_id::text)
        || '/snapshots/' || target_snapshot_kind
        || '/' || lower(target_snapshot_id::text) || '.json';
$$;

alter table public.session_snapshots
    drop constraint if exists session_snapshots_payload_path_check;
alter table public.session_snapshots
    add constraint session_snapshots_payload_path_check
    check (
        payload_storage_path = public.session_snapshot_expected_storage_path(
            org_id,
            property_id,
            session_id,
            snapshot_kind,
            id
        )
    );

drop trigger if exists set_session_snapshots_updated_at on public.session_snapshots;
create trigger set_session_snapshots_updated_at
    before update on public.session_snapshots
    for each row
    execute function public.set_updated_at();

create index if not exists idx_session_snapshots_session_created
    on public.session_snapshots (session_id, created_at desc)
    where deleted_at is null;

create index if not exists idx_session_snapshots_org_created
    on public.session_snapshots (org_id, created_at desc)
    where deleted_at is null;

create index if not exists idx_session_snapshots_property_kind_created
    on public.session_snapshots (property_id, snapshot_kind, created_at desc)
    where deleted_at is null;

create unique index if not exists idx_session_snapshots_payload_active
    on public.session_snapshots (payload_storage_bucket, payload_storage_path)
    where deleted_at is null;

create index if not exists idx_session_snapshots_payload_sha
    on public.session_snapshots (snapshot_payload_sha256)
    where deleted_at is null;

create or replace function public.session_snapshot_storage_path_is_well_formed(object_name text)
returns boolean
language sql
immutable
as $$
    select object_name ~ '^orgs/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/properties/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/sessions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/snapshots/(draft|completed|export|delivery|manual)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$';
$$;

create or replace function public.session_snapshot_storage_org_id(object_name text)
returns uuid
language sql
stable
as $$
    select case
        when public.session_snapshot_storage_path_is_well_formed(object_name)
        then split_part(object_name, '/', 2)::uuid
        else null::uuid
    end;
$$;

create or replace function public.session_snapshot_storage_property_id(object_name text)
returns uuid
language sql
stable
as $$
    select case
        when public.session_snapshot_storage_path_is_well_formed(object_name)
        then split_part(object_name, '/', 4)::uuid
        else null::uuid
    end;
$$;

create or replace function public.session_snapshot_storage_session_id(object_name text)
returns uuid
language sql
stable
as $$
    select case
        when public.session_snapshot_storage_path_is_well_formed(object_name)
        then split_part(object_name, '/', 6)::uuid
        else null::uuid
    end;
$$;

create or replace function public.session_snapshot_storage_kind(object_name text)
returns text
language sql
stable
as $$
    select case
        when public.session_snapshot_storage_path_is_well_formed(object_name)
        then split_part(object_name, '/', 8)
        else null::text
    end;
$$;

create or replace function public.session_snapshot_storage_snapshot_id(object_name text)
returns uuid
language sql
stable
as $$
    select case
        when public.session_snapshot_storage_path_is_well_formed(object_name)
        then replace(split_part(object_name, '/', 9), '.json', '')::uuid
        else null::uuid
    end;
$$;

alter table public.session_snapshots enable row level security;

revoke all on public.session_snapshots from anon, authenticated;
grant select, insert on public.session_snapshots to authenticated;
grant select, insert, update, delete on public.session_snapshots to service_role;

drop policy if exists session_snapshots_select_member on public.session_snapshots;
create policy session_snapshots_select_member
on public.session_snapshots
for select
to authenticated
using (
    deleted_at is null
    and public.has_session_access(org_id, session_id)
);

drop policy if exists session_snapshots_insert_owner_manager_field on public.session_snapshots;
create policy session_snapshots_insert_owner_manager_field
on public.session_snapshots
for insert
to authenticated
with check (
    public.has_org_role(org_id, array['owner', 'manager', 'field'])
    and public.session_snapshot_row_matches_parents(org_id, property_id, session_id)
    and public.has_session_access(org_id, session_id)
    and public.updated_by_matches_actor(created_by)
    and public.updated_by_matches_actor(updated_by)
    and payload_storage_bucket = 'scoutcapture-session-snapshots'
    and payload_storage_path = public.session_snapshot_expected_storage_path(
        org_id,
        property_id,
        session_id,
        snapshot_kind,
        id
    )
);

drop policy if exists session_snapshots_update_denied on public.session_snapshots;
create policy session_snapshots_update_denied
on public.session_snapshots
for update
to authenticated
using (false)
with check (false);

drop policy if exists session_snapshots_delete_denied on public.session_snapshots;
create policy session_snapshots_delete_denied
on public.session_snapshots
for delete
to authenticated
using (false);

drop policy if exists session_snapshot_objects_select_with_visible_row on storage.objects;
create policy session_snapshot_objects_select_with_visible_row
on storage.objects
for select
to authenticated
using (
    bucket_id = 'scoutcapture-session-snapshots'
    and public.session_snapshot_storage_path_is_well_formed(name)
    and exists (
        select 1
        from public.session_snapshots snapshot
        where snapshot.id = public.session_snapshot_storage_snapshot_id(name)
          and snapshot.org_id = public.session_snapshot_storage_org_id(name)
          and snapshot.property_id = public.session_snapshot_storage_property_id(name)
          and snapshot.session_id = public.session_snapshot_storage_session_id(name)
          and snapshot.snapshot_kind = public.session_snapshot_storage_kind(name)
          and snapshot.payload_storage_bucket = bucket_id
          and snapshot.payload_storage_path = name
          and snapshot.deleted_at is null
          and public.has_session_access(snapshot.org_id, snapshot.session_id)
    )
);

drop policy if exists session_snapshot_objects_insert_owner_manager_field on storage.objects;
create policy session_snapshot_objects_insert_owner_manager_field
on storage.objects
for insert
to authenticated
with check (
    bucket_id = 'scoutcapture-session-snapshots'
    and public.session_snapshot_storage_path_is_well_formed(name)
    and public.has_org_role(
        public.session_snapshot_storage_org_id(name),
        array['owner', 'manager', 'field']
    )
    and public.session_snapshot_row_matches_parents(
        public.session_snapshot_storage_org_id(name),
        public.session_snapshot_storage_property_id(name),
        public.session_snapshot_storage_session_id(name)
    )
    and public.has_session_access(
        public.session_snapshot_storage_org_id(name),
        public.session_snapshot_storage_session_id(name)
    )
);

drop policy if exists session_snapshot_objects_update_denied on storage.objects;
create policy session_snapshot_objects_update_denied
on storage.objects
for update
to authenticated
using (bucket_id = 'scoutcapture-session-snapshots' and false)
with check (false);

drop policy if exists session_snapshot_objects_delete_denied on storage.objects;
create policy session_snapshot_objects_delete_denied
on storage.objects
for delete
to authenticated
using (bucket_id = 'scoutcapture-session-snapshots' and false);

comment on table public.session_snapshots is
'Remote session snapshot metadata. Normalized rows remain portal collaboration/edit state; immutable completed snapshots are restore/package state. Portal edits should update normalized trade/priority/description rows, not completed snapshot payloads.';

create extension if not exists pgcrypto;

create table if not exists public.orgs (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    slug text,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid,
    revision bigint not null default 1,
    deleted_at timestamptz
);

create table if not exists public.users_profile (
    id uuid primary key references auth.users(id) on delete cascade,
    email text,
    full_name text,
    avatar_url text,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid,
    revision bigint not null default 1,
    deleted_at timestamptz
);

alter table public.orgs
    add constraint orgs_updated_by_fkey
    foreign key (updated_by) references public.users_profile(id);

alter table public.users_profile
    add constraint users_profile_updated_by_fkey
    foreign key (updated_by) references public.users_profile(id);

create table if not exists public.org_memberships (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    user_id uuid not null references public.users_profile(id),
    role text not null default 'field',
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid references public.users_profile(id),
    revision bigint not null default 1,
    deleted_at timestamptz,
    unique (org_id, user_id)
);

create table if not exists public.properties (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    name text not null,
    address_line1 text,
    address_line2 text,
    city text,
    state text,
    postal_code text,
    country_code text,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid references public.users_profile(id),
    revision bigint not null default 1,
    deleted_at timestamptz
);

create table if not exists public.sessions (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    property_id uuid not null references public.properties(id),
    title text,
    status text,
    started_at timestamptz,
    completed_at timestamptz,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid references public.users_profile(id),
    revision bigint not null default 1,
    deleted_at timestamptz
);

create table if not exists public.shots (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    session_id uuid not null references public.sessions(id),
    shot_type text,
    position integer,
    captured_at timestamptz,
    storage_bucket text,
    storage_path text,
    checksum_sha256 text,
    byte_size bigint,
    upload_state text not null default 'pending',
    upload_attempts integer not null default 0,
    last_upload_error text,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid references public.users_profile(id),
    revision bigint not null default 1,
    deleted_at timestamptz
);

create table if not exists public.observations (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    session_id uuid not null references public.sessions(id),
    shot_id uuid,
    category text,
    status text,
    title text,
    detail text,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid references public.users_profile(id),
    revision bigint not null default 1,
    deleted_at timestamptz
);

create table if not exists public.session_events (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    session_id uuid not null references public.sessions(id),
    event_type text not null,
    payload jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default timezone('utc', now())
);

alter table public.observations
    add constraint observations_shot_id_fkey
    foreign key (shot_id) references public.shots(id);

alter table public.org_memberships
    add constraint org_memberships_role_check
    check (role in ('owner', 'manager', 'field', 'viewer'));

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := timezone('utc', now());
    return new;
end;
$$;

create trigger set_orgs_updated_at
    before update on public.orgs
    for each row
    execute function public.set_updated_at();

create trigger set_users_profile_updated_at
    before update on public.users_profile
    for each row
    execute function public.set_updated_at();

create trigger set_org_memberships_updated_at
    before update on public.org_memberships
    for each row
    execute function public.set_updated_at();

create trigger set_properties_updated_at
    before update on public.properties
    for each row
    execute function public.set_updated_at();

create trigger set_sessions_updated_at
    before update on public.sessions
    for each row
    execute function public.set_updated_at();

create trigger set_shots_updated_at
    before update on public.shots
    for each row
    execute function public.set_updated_at();

create trigger set_observations_updated_at
    before update on public.observations
    for each row
    execute function public.set_updated_at();

create index if not exists idx_orgs_active on public.orgs (updated_at desc) where deleted_at is null;
create unique index if not exists idx_orgs_slug_active on public.orgs (slug) where slug is not null and deleted_at is null;

create index if not exists idx_users_profile_active on public.users_profile (updated_at desc) where deleted_at is null;
create index if not exists idx_users_profile_email_active on public.users_profile (email) where email is not null and deleted_at is null;

create index if not exists idx_org_memberships_org_active on public.org_memberships (org_id, role) where deleted_at is null;
create index if not exists idx_org_memberships_user_active on public.org_memberships (user_id) where deleted_at is null;

create index if not exists idx_properties_org_active on public.properties (org_id, updated_at desc) where deleted_at is null;
create index if not exists idx_properties_org_name_active on public.properties (org_id, name) where deleted_at is null;

create index if not exists idx_sessions_org_active on public.sessions (org_id, updated_at desc) where deleted_at is null;
create index if not exists idx_sessions_property_active on public.sessions (property_id, updated_at desc) where deleted_at is null;
create index if not exists idx_sessions_property_status_active on public.sessions (property_id, status) where deleted_at is null;

create index if not exists idx_shots_session_active on public.shots (session_id, position) where deleted_at is null;
create index if not exists idx_shots_org_active on public.shots (org_id, updated_at desc) where deleted_at is null;
create index if not exists idx_shots_upload_state_active on public.shots (upload_state, updated_at asc) where deleted_at is null;
create unique index if not exists idx_shots_storage_path_active on public.shots (storage_bucket, storage_path) where storage_bucket is not null and storage_path is not null and deleted_at is null;

create index if not exists idx_observations_session_active on public.observations (session_id, updated_at desc) where deleted_at is null;
create index if not exists idx_observations_shot_active on public.observations (shot_id) where shot_id is not null and deleted_at is null;
create index if not exists idx_observations_org_status_active on public.observations (org_id, status) where deleted_at is null;

create index if not exists idx_session_events_session_created on public.session_events (session_id, created_at desc);
create index if not exists idx_session_events_org_created on public.session_events (org_id, created_at desc);
create index if not exists idx_session_events_type_created on public.session_events (event_type, created_at desc);

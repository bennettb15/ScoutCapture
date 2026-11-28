-- Source: scout-site@ef46714:supabase/migrations/202609080001_portal_property_access_scope.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
create extension if not exists pgcrypto;

alter table public.org_memberships
    add column if not exists access_scope text not null default 'org';

alter table public.org_memberships
    drop constraint if exists org_memberships_access_scope_check;

alter table public.org_memberships
    add constraint org_memberships_access_scope_check
    check (access_scope in ('org', 'property'));

create table if not exists public.property_access_grants (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    property_id uuid not null references public.properties(id),
    user_id uuid not null references public.users_profile(id),
    granted_by uuid not null references public.users_profile(id),
    created_at timestamptz not null default timezone('utc', now()),
    deleted_at timestamptz
);

create unique index if not exists idx_property_access_grants_active_unique
    on public.property_access_grants (org_id, property_id, user_id)
    where deleted_at is null;

create index if not exists idx_property_access_grants_user_active
    on public.property_access_grants (user_id, org_id)
    where deleted_at is null;

create index if not exists idx_property_access_grants_property_active
    on public.property_access_grants (property_id, user_id)
    where deleted_at is null;

alter table public.portal_invites
    drop constraint if exists portal_invites_role_check;

alter table public.portal_invites
    add constraint portal_invites_role_check
    check (role in ('viewer', 'field', 'manager', 'owner'));

alter table public.portal_invites
    drop constraint if exists portal_invites_access_scope_check;

alter table public.portal_invites
    add constraint portal_invites_access_scope_check
    check (
        access_scope in ('org', 'property')
        and (role <> 'owner' or access_scope = 'org')
    );

create table if not exists public.portal_invite_property_grants (
    id uuid primary key default gen_random_uuid(),
    invite_id uuid not null references public.portal_invites(id) on delete cascade,
    org_id uuid not null references public.orgs(id),
    property_id uuid not null references public.properties(id),
    created_at timestamptz not null default timezone('utc', now())
);

create unique index if not exists idx_portal_invite_property_grants_unique
    on public.portal_invite_property_grants (invite_id, property_id);

create index if not exists idx_portal_invite_property_grants_invite
    on public.portal_invite_property_grants (invite_id);

alter table public.portal_invite_property_grants enable row level security;

drop policy if exists "portal_invite_property_grants_service_role_all"
    on public.portal_invite_property_grants;

create policy "portal_invite_property_grants_service_role_all"
    on public.portal_invite_property_grants
    using (auth.role() = 'service_role')
    with check (auth.role() = 'service_role');

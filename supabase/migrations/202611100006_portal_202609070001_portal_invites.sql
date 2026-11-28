-- Source: scout-site@ef46714:supabase/migrations/202609070001_portal_invites.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
create extension if not exists pgcrypto;

create table if not exists public.portal_invites (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    email text not null,
    role text not null check (role in ('viewer', 'field')),
    access_scope text not null default 'org' check (access_scope = 'org'),
    token_hash text not null unique,
    created_by uuid references public.users_profile(id),
    updated_by uuid references public.users_profile(id),
    accepted_by uuid references public.users_profile(id),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    last_sent_at timestamptz,
    expires_at timestamptz not null default (now() + interval '7 days'),
    accepted_at timestamptz,
    revoked_at timestamptz,
    revoked_reason text
);

create unique index if not exists idx_portal_invites_one_pending_per_org_email
    on public.portal_invites (org_id, lower(email))
    where accepted_at is null and revoked_at is null;

create index if not exists idx_portal_invites_org_pending
    on public.portal_invites (org_id, created_at desc)
    where accepted_at is null and revoked_at is null;

create index if not exists idx_portal_invites_token_hash
    on public.portal_invites (token_hash);

alter table public.portal_invites enable row level security;

drop policy if exists "portal_invites_service_role_all" on public.portal_invites;
create policy "portal_invites_service_role_all"
    on public.portal_invites
    using (auth.role() = 'service_role')
    with check (auth.role() = 'service_role');

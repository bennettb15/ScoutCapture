alter table public.sessions
    add column if not exists locked_by_user_id uuid references public.users_profile(id),
    add column if not exists locked_by_device_id text,
    add column if not exists locked_at timestamptz,
    add column if not exists coordination_tier1_snapshot text;

create index if not exists idx_sessions_locked_by_user_active
    on public.sessions (locked_by_user_id)
    where deleted_at is null and locked_by_user_id is not null;

create index if not exists idx_sessions_locked_at_active
    on public.sessions (locked_at desc)
    where deleted_at is null and locked_at is not null;

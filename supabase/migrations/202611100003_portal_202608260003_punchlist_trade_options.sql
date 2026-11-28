-- Source: scout-site@ef46714:supabase/migrations/202608260003_punchlist_trade_options.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Portal-side master trade list for Scout Website punchlist workflow fields.
-- This is intentionally global for v1 and does not touch ScoutCapture or exports.

create table if not exists public.punchlist_trade_options (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    trade_key text not null,
    is_active boolean not null default true,
    created_by uuid references public.users_profile(id),
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now()),
    deleted_at timestamptz
);

create or replace function public.punchlist_trade_option_key(input text)
returns text
language sql
immutable
as $$
    select trim(both '_' from regexp_replace(
        regexp_replace(lower(trim(coalesce(input, ''))), '&', ' and ', 'g'),
        '[^a-z0-9]+',
        '_',
        'g'
    ));
$$;

alter table public.punchlist_trade_options
    drop constraint if exists punchlist_trade_options_name_check;
alter table public.punchlist_trade_options
    add constraint punchlist_trade_options_name_check
    check (
        nullif(trim(name), '') is not null
        and length(trim(name)) <= 60
        and punchlist_trade_option_key(name) = trade_key
    );

create unique index if not exists idx_punchlist_trade_options_key_active
    on public.punchlist_trade_options (trade_key)
    where deleted_at is null;

create index if not exists idx_punchlist_trade_options_active_name
    on public.punchlist_trade_options (is_active, name)
    where deleted_at is null;

insert into public.punchlist_trade_options (name, trade_key, is_active)
values
    ('General', public.punchlist_trade_option_key('General'), true),
    ('Roofing', public.punchlist_trade_option_key('Roofing'), true),
    ('Masonry', public.punchlist_trade_option_key('Masonry'), true),
    ('Siding', public.punchlist_trade_option_key('Siding'), true),
    ('Windows', public.punchlist_trade_option_key('Windows'), true),
    ('Doors', public.punchlist_trade_option_key('Doors'), true),
    ('Electrical', public.punchlist_trade_option_key('Electrical'), true),
    ('Plumbing', public.punchlist_trade_option_key('Plumbing'), true),
    ('HVAC', public.punchlist_trade_option_key('HVAC'), true),
    ('Landscaping', public.punchlist_trade_option_key('Landscaping'), true),
    ('Paint', public.punchlist_trade_option_key('Paint'), true),
    ('Carpentry', public.punchlist_trade_option_key('Carpentry'), true),
    ('Concrete', public.punchlist_trade_option_key('Concrete'), true),
    ('Gutters', public.punchlist_trade_option_key('Gutters'), true),
    ('Other', public.punchlist_trade_option_key('Other'), true)
on conflict (trade_key) where deleted_at is null do nothing;

alter table public.punchlist_trade_options enable row level security;

revoke all on public.punchlist_trade_options from anon, authenticated;
grant select on public.punchlist_trade_options to authenticated;
grant select, insert, update, delete on public.punchlist_trade_options to service_role;

drop policy if exists punchlist_trade_options_select_active on public.punchlist_trade_options;
create policy punchlist_trade_options_select_active
on public.punchlist_trade_options
for select
to authenticated
using (
    is_active = true
    and deleted_at is null
);

drop policy if exists punchlist_trade_options_insert_denied on public.punchlist_trade_options;
create policy punchlist_trade_options_insert_denied
on public.punchlist_trade_options
for insert
to authenticated
with check (false);

drop policy if exists punchlist_trade_options_update_denied on public.punchlist_trade_options;
create policy punchlist_trade_options_update_denied
on public.punchlist_trade_options
for update
to authenticated
using (false)
with check (false);

drop policy if exists punchlist_trade_options_delete_denied on public.punchlist_trade_options;
create policy punchlist_trade_options_delete_denied
on public.punchlist_trade_options
for delete
to authenticated
using (false);

comment on table public.punchlist_trade_options is
'Global portal-side trade options for Scout Website punchlist workflow fields. Does not sync to ScoutCapture or report exports.';

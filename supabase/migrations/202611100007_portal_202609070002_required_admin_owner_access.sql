-- Source: scout-site@ef46714:supabase/migrations/202609070002_required_admin_owner_access.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
create or replace function public.ensure_required_admin_owner_memberships(target_org_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.users_profile (
        id,
        email,
        deleted_at
    )
    select
        auth_user.id,
        lower(auth_user.email),
        null
    from auth.users auth_user
    where lower(auth_user.email) in ('bennettb15@gmail.com', 'brian@scoutclear.com')
    on conflict (id) do update
    set email = excluded.email,
        deleted_at = null;

    insert into public.org_memberships (
        org_id,
        user_id,
        role,
        access_scope,
        deleted_at
    )
    select
        org_row.id,
        auth_user.id,
        'owner',
        'org',
        null
    from public.orgs org_row
    cross join auth.users auth_user
    where org_row.deleted_at is null
      and (target_org_id is null or org_row.id = target_org_id)
      and lower(auth_user.email) in ('bennettb15@gmail.com', 'brian@scoutclear.com')
    on conflict (org_id, user_id) do update
    set role = 'owner',
        access_scope = 'org',
        deleted_at = null;
end;
$$;

create or replace function public.ensure_required_admin_owner_memberships_for_new_org()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    perform public.ensure_required_admin_owner_memberships(new.id);
    return new;
end;
$$;

select public.ensure_required_admin_owner_memberships();

drop trigger if exists ensure_required_admin_owner_memberships_after_org_insert on public.orgs;
create trigger ensure_required_admin_owner_memberships_after_org_insert
    after insert on public.orgs
    for each row
    execute function public.ensure_required_admin_owner_memberships_for_new_org();

grant execute on function public.ensure_required_admin_owner_memberships(uuid) to service_role;

comment on function public.ensure_required_admin_owner_memberships(uuid) is
    'Ensures required Scout admin accounts are active org-wide owners for all existing orgs or one target org.';

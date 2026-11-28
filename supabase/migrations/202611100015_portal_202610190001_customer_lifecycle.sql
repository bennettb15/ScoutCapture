-- Source: scout-site@ef46714:supabase/migrations/202610190001_customer_lifecycle.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Private commercial dates for one organization. Only the service role can read
-- or change these rows; the website API separately limits access to Brian's
-- two admin logins.
create table if not exists public.customer_lifecycle (
    org_id uuid primary key references public.orgs(id) on delete cascade,
    pilot_signed_at timestamptz,
    pilot_expires_at timestamptz,
    ongoing_started_at timestamptz,
    ongoing_expires_at timestamptz,
    access_ended_at timestamptz,
    internal_notes text not null default '',
    updated_at timestamptz not null default now(),
    updated_by uuid,
    constraint customer_lifecycle_pilot_pair check (
        (pilot_signed_at is null and pilot_expires_at is null)
        or (pilot_signed_at is not null and pilot_expires_at > pilot_signed_at)
    ),
    constraint customer_lifecycle_ongoing_pair check (
        (ongoing_started_at is null and ongoing_expires_at is null)
        or (ongoing_started_at is not null and ongoing_expires_at > ongoing_started_at)
    ),
    constraint customer_lifecycle_notes_length check (length(internal_notes) <= 2000)
);

create index if not exists customer_lifecycle_pilot_due_idx
    on public.customer_lifecycle (pilot_expires_at)
    where access_ended_at is null and ongoing_started_at is null;
create index if not exists customer_lifecycle_ongoing_due_idx
    on public.customer_lifecycle (ongoing_expires_at)
    where access_ended_at is null and ongoing_started_at is not null;

alter table public.customer_lifecycle enable row level security;
revoke all on public.customer_lifecycle from anon, authenticated;
grant select, insert, update, delete on public.customer_lifecycle to service_role;

-- This runs in the existing daily deletion cron. It revokes customer memberships
-- and unused invitations, leaving platform admin access for record cleanup.
-- The existing retention reconciliation then starts its 90-day countdown.
create or replace function public.expire_due_customer_access(
    trusted_admin_emails text[] default '{}'::text[]
)
returns table (expired_org_id uuid, revoked_memberships integer, revoked_invites integer)
language plpgsql
security definer
set search_path = public
as $$
declare
    target record;
    membership_count integer;
    invite_count integer;
    ended_at timestamptz;
begin
    if cardinality(trusted_admin_emails) = 0 then
        raise exception 'Platform admin exclusion list is required';
    end if;

    for target in
        select lifecycle.org_id
          from public.customer_lifecycle lifecycle
         where case
                 when lifecycle.ongoing_started_at <= now()
                   then lifecycle.ongoing_expires_at
                 else lifecycle.pilot_expires_at
               end <= now()
           and (
               lifecycle.access_ended_at is null
               or case
                    when lifecycle.ongoing_started_at <= now()
                      then lifecycle.ongoing_expires_at
                    else lifecycle.pilot_expires_at
                  end > lifecycle.access_ended_at
           )
         order by coalesce(lifecycle.ongoing_expires_at, lifecycle.pilot_expires_at)
         for update skip locked
    loop
        ended_at := now();
        update public.org_memberships member
           set deleted_at = ended_at
         where member.org_id = target.org_id
           and member.deleted_at is null
           and coalesce((
               select lower(profile.email)
                 from public.users_profile profile
                where profile.id = member.user_id
           ), '') <> all(trusted_admin_emails);
        get diagnostics membership_count = row_count;

        update public.portal_invites invite
           set revoked_at = ended_at,
               revoked_reason = 'customer_term_expired',
               updated_at = ended_at
         where invite.org_id = target.org_id
           and invite.accepted_at is null
           and invite.revoked_at is null;
        get diagnostics invite_count = row_count;

        update public.customer_lifecycle lifecycle
           set access_ended_at = ended_at,
               updated_at = ended_at
         where lifecycle.org_id = target.org_id;

        expired_org_id := target.org_id;
        revoked_memberships := membership_count;
        revoked_invites := invite_count;
        return next;
    end loop;
end;
$$;

revoke all on function public.expire_due_customer_access(text[]) from public, anon, authenticated;
grant execute on function public.expire_due_customer_access(text[]) to service_role;

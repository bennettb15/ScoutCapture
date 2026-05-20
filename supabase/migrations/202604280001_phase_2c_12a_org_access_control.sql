create table if not exists public.org_invitations (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id),
    invitee_email text not null,
    role text not null default 'viewer',
    invited_by uuid not null references public.users_profile(id),
    created_at timestamptz not null default timezone('utc', now()),
    accepted_at timestamptz,
    revoked_at timestamptz
);

alter table public.org_invitations
    add constraint org_invitations_role_check
    check (role in ('owner', 'manager', 'field', 'viewer'));

create unique index if not exists idx_org_invitations_active_pending
on public.org_invitations (org_id, lower(invitee_email))
where accepted_at is null and revoked_at is null;

create index if not exists idx_org_invitations_invitee_pending
on public.org_invitations (lower(invitee_email), created_at desc)
where accepted_at is null and revoked_at is null;

create index if not exists idx_org_invitations_org_pending
on public.org_invitations (org_id, created_at desc)
where accepted_at is null and revoked_at is null;

alter table public.org_invitations enable row level security;

revoke all on public.org_invitations from anon, authenticated;
grant select on public.org_invitations to authenticated;

drop policy if exists org_invitations_select_owner_or_invitee on public.org_invitations;
create policy org_invitations_select_owner_or_invitee
on public.org_invitations
for select
to authenticated
using (
    (
        revoked_at is null
        and lower(invitee_email) = lower(
            coalesce(
                nullif(auth.email(), ''),
                nullif(auth.jwt() ->> 'email', ''),
                ''
            )
        )
    )
    or public.has_org_role(org_id, array['owner'])
);

create or replace function public.list_pending_org_invitations()
returns table (
    id uuid,
    org_id uuid,
    org_name text,
    invitee_email text,
    role text,
    created_at timestamptz,
    invited_by uuid
)
language sql
stable
security definer
set search_path = public
as $$
    select
        invitation.id,
        invitation.org_id,
        org.name as org_name,
        invitation.invitee_email,
        invitation.role,
        invitation.created_at,
        invitation.invited_by
    from public.org_invitations invitation
    join public.orgs org
      on org.id = invitation.org_id
    where invitation.accepted_at is null
      and invitation.revoked_at is null
      and lower(invitation.invitee_email) = lower(
          coalesce(
              nullif(auth.email(), ''),
              nullif(auth.jwt() ->> 'email', ''),
              ''
          )
      );
$$;

create or replace function public.create_org_invitation(
    target_org_id uuid,
    target_invitee_email text,
    target_role text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    actor_id uuid := auth.uid();
    normalized_email text := lower(trim(target_invitee_email));
    normalized_role text := lower(trim(target_role));
    invitation_id uuid := gen_random_uuid();
begin
    if actor_id is null then
        raise exception 'Authenticated user required';
    end if;

    if not public.has_org_role(target_org_id, array['owner']) then
        raise exception 'Only org owners can invite users';
    end if;

    if normalized_email is null or normalized_email = '' then
        raise exception 'Invitee email is required';
    end if;

    if normalized_role not in ('owner', 'manager', 'field', 'viewer') then
        raise exception 'Invalid org invitation role';
    end if;

    if exists (
        select 1
        from public.users_profile profile
        join public.org_memberships membership
          on membership.user_id = profile.id
        where membership.org_id = target_org_id
          and membership.deleted_at is null
          and lower(coalesce(profile.email, '')) = normalized_email
    ) then
        raise exception 'User already has active org access';
    end if;

    insert into public.org_invitations (
        id,
        org_id,
        invitee_email,
        role,
        invited_by
    )
    values (
        invitation_id,
        target_org_id,
        normalized_email,
        normalized_role,
        actor_id
    );

    return invitation_id;
exception
    when unique_violation then
        raise exception 'Active invite already exists for this organization and email';
end;
$$;

create or replace function public.accept_org_invitation(
    target_invitation_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    actor_id uuid := public.ensure_current_user_profile();
    actor_email text := lower(trim(
        coalesce(
            nullif(auth.email(), ''),
            nullif(auth.jwt() ->> 'email', ''),
            ''
        )
    ));
    invitation_row public.org_invitations%rowtype;
begin
    if actor_id is null then
        raise exception 'Authenticated user required';
    end if;

    if actor_email = '' then
        raise exception 'Authenticated email required';
    end if;

    select *
    into invitation_row
    from public.org_invitations
    where id = target_invitation_id
      and accepted_at is null
      and revoked_at is null
      and lower(invitee_email) = actor_email
    for update;

    if not found then
        raise exception 'Pending invitation not found for the authenticated user';
    end if;

    insert into public.org_memberships (
        org_id,
        user_id,
        role,
        updated_by,
        deleted_at
    )
    values (
        invitation_row.org_id,
        actor_id,
        invitation_row.role,
        actor_id,
        null
    )
    on conflict (org_id, user_id) do update
    set role = excluded.role,
        updated_by = excluded.updated_by,
        deleted_at = null;

    update public.org_invitations
    set accepted_at = timezone('utc', now())
    where id = invitation_row.id;

    return invitation_row.org_id;
end;
$$;

create or replace function public.revoke_org_access(
    target_org_id uuid,
    target_user_id uuid default null,
    target_invitation_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    actor_id uuid := auth.uid();
    target_membership_role text;
begin
    if actor_id is null then
        raise exception 'Authenticated user required';
    end if;

    if not public.has_org_role(target_org_id, array['owner']) then
        raise exception 'Only org owners can revoke org access';
    end if;

    if (target_user_id is null and target_invitation_id is null)
        or (target_user_id is not null and target_invitation_id is not null) then
        raise exception 'Provide either target_user_id or target_invitation_id';
    end if;

    if target_user_id is not null then
        select role
        into target_membership_role
        from public.org_memberships
        where org_id = target_org_id
          and user_id = target_user_id
          and deleted_at is null
        for update;

        if not found then
            raise exception 'Active org membership not found';
        end if;

        if target_membership_role = 'owner' then
            raise exception 'Owner memberships cannot be revoked via this RPC';
        end if;

        update public.org_memberships
        set deleted_at = timezone('utc', now()),
            updated_by = actor_id
        where org_id = target_org_id
          and user_id = target_user_id
          and deleted_at is null;

        return true;
    end if;

    update public.org_invitations
    set revoked_at = timezone('utc', now())
    where id = target_invitation_id
      and org_id = target_org_id
      and accepted_at is null
      and revoked_at is null;

    if not found then
        raise exception 'Active org invitation not found';
    end if;

    return true;
end;
$$;

grant execute on function public.create_org_invitation(uuid, text, text) to authenticated;
grant execute on function public.list_pending_org_invitations() to authenticated;
grant execute on function public.accept_org_invitation(uuid) to authenticated;
grant execute on function public.revoke_org_access(uuid, uuid, uuid) to authenticated;

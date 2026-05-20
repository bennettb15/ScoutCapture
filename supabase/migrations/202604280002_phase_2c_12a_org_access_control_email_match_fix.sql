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

grant execute on function public.list_pending_org_invitations() to authenticated;
grant execute on function public.accept_org_invitation(uuid) to authenticated;

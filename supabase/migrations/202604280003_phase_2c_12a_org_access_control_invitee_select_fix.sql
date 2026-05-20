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

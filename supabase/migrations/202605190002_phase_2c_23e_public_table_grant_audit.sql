-- Phase 2C-23E: Explicit public table grants for Supabase Data API rollout.
--
-- Supabase is moving public-schema Data API exposure behind explicit GRANTs.
-- RLS remains the row-level guard; these grants only preserve intended table-level
-- API reachability for existing ScoutCapture tables. No RLS policies are changed here.

grant usage on schema public to authenticated;
grant usage on schema public to service_role;

revoke all on public.orgs from public, anon, authenticated;
revoke all on public.users_profile from public, anon, authenticated;
revoke all on public.org_memberships from public, anon, authenticated;
revoke all on public.properties from public, anon, authenticated;
revoke all on public.sessions from public, anon, authenticated;
revoke all on public.shots from public, anon, authenticated;
revoke all on public.observations from public, anon, authenticated;
revoke all on public.session_events from public, anon, authenticated;
revoke all on public.org_invitations from public, anon, authenticated;
revoke all on public.property_access_grants from public, anon, authenticated;
revoke all on public.property_session_occupancy from public, anon, authenticated;
revoke all on public.session_snapshots from public, anon, authenticated;

-- Core organization/profile tables. RLS scopes rows by self/org membership.
grant select, update on public.orgs to authenticated;
grant select, insert, update on public.users_profile to authenticated;
grant select, insert, update on public.org_memberships to authenticated;

-- Canonical app metadata tables. RLS keeps property/session/shot/observation
-- access scoped to org role and property grants.
grant select, insert, update on public.properties to authenticated;
grant select, insert, update on public.sessions to authenticated;
grant select, insert, update on public.shots to authenticated;
grant select, insert, update on public.observations to authenticated;

-- Audit/session event rows are append/read only for app clients.
grant select, insert on public.session_events to authenticated;

-- Invitations are selected directly but mutated through SECURITY DEFINER RPCs.
grant select on public.org_invitations to authenticated;

-- Property-scoped access management is directly managed by owner-only RLS.
grant select, insert, update on public.property_access_grants to authenticated;

-- Occupancy rows are active coordination markers; app clients need CRUD with RLS.
grant select, insert, update, delete on public.property_session_occupancy to authenticated;

-- Session snapshots are append/read only for app clients; completed snapshots
-- remain effectively immutable until a controlled service-role/RPC supersession path exists.
grant select, insert on public.session_snapshots to authenticated;

-- Service role keeps operational access for maintenance, RPC internals, and future
-- controlled snapshot supersession/cleanup paths. RLS bypass semantics still apply
-- according to Supabase service-role behavior.
grant select, insert, update, delete on public.orgs to service_role;
grant select, insert, update, delete on public.users_profile to service_role;
grant select, insert, update, delete on public.org_memberships to service_role;
grant select, insert, update, delete on public.properties to service_role;
grant select, insert, update, delete on public.sessions to service_role;
grant select, insert, update, delete on public.shots to service_role;
grant select, insert, update, delete on public.observations to service_role;
grant select, insert, update, delete on public.session_events to service_role;
grant select, insert, update, delete on public.org_invitations to service_role;
grant select, insert, update, delete on public.property_access_grants to service_role;
grant select, insert, update, delete on public.property_session_occupancy to service_role;
grant select, insert, update, delete on public.session_snapshots to service_role;

comment on table public.orgs is
'ScoutCapture app table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.users_profile is
'ScoutCapture app table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.org_memberships is
'ScoutCapture app table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.properties is
'ScoutCapture app table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.sessions is
'ScoutCapture app table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.shots is
'ScoutCapture app table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.observations is
'ScoutCapture app table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.session_events is
'ScoutCapture append/read audit table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.org_invitations is
'ScoutCapture invitation table. Direct authenticated access is select-only; mutations use RPCs. Explicit Data API grants are maintained by Phase 2C-23E.';
comment on table public.property_access_grants is
'ScoutCapture property access table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.property_session_occupancy is
'ScoutCapture coordination occupancy table. Explicit Data API grants are maintained by Phase 2C-23E; RLS remains the row-level guard.';
comment on table public.session_snapshots is
'ScoutCapture remote session snapshot metadata. Explicit Data API grants are maintained by Phase 2C-23E; app clients are append/read only and RLS remains the row-level guard.';

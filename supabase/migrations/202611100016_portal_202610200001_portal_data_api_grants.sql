-- Source: scout-site@ef46714:supabase/migrations/202610200001_portal_data_api_grants.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Keep portal tables reachable through the Data API when new public tables no
-- longer receive automatic grants. Portal invitations are server-only.
grant usage on schema public to service_role;

revoke all on public.portal_invites from public, anon, authenticated;
revoke all on public.portal_invite_property_grants from public, anon, authenticated;

grant select, insert, update, delete on public.portal_invites to service_role;
grant select, insert, update, delete on public.portal_invite_property_grants to service_role;

-- The website uses the service role for property scopes. Scout Capture already
-- grants authenticated SELECT/INSERT/UPDATE with owner-scoped RLS in its own
-- migrations; leave those permissions and policies intact.
grant select, insert, update, delete on public.property_access_grants to service_role;

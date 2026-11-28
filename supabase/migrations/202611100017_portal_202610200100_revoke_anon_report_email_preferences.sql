-- Source: scout-site@ef46714:supabase/migrations/202610200100_revoke_anon_report_email_preferences.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Report email settings belong to signed-in organization members.
-- Keep authenticated and service-role grants unchanged; RLS continues to
-- restrict members and owners to the appropriate organization.
revoke all privileges on table public.report_email_org_settings from anon;
revoke all privileges on table public.report_email_user_preferences from anon;

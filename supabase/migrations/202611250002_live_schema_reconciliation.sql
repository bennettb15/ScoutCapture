-- Reconcile live 1.3 backend behavior that differs from repository migrations.
-- Source: scout-dev public catalog on 2026-11-27; no data copied.

CREATE OR REPLACE FUNCTION public.property_has_active_occupancy(target_property_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select to_regclass('public.property_session_occupancy') is not null
        and exists (
            select 1
            from public.property_session_occupancy occupancy
            where occupancy.property_id = target_property_id
              and (
                  occupancy.occupied_by_user_id is not null
                  or nullif(btrim(coalesce(occupancy.occupied_by_device_id, '')), '') is not null
                  or occupancy.occupied_at is not null
              )
        );
$function$;

alter table public.report_email_org_settings alter column created_at set default now();
alter table public.report_email_org_settings alter column updated_at set default now();
drop trigger if exists set_report_email_org_settings_updated_at on public.report_email_org_settings;
CREATE TRIGGER report_email_org_settings_set_updated_at BEFORE UPDATE ON public.report_email_org_settings FOR EACH ROW EXECUTE FUNCTION set_updated_at();
drop policy if exists report_email_org_settings_select_member on public.report_email_org_settings;
drop policy if exists report_email_org_settings_update_owner on public.report_email_org_settings;
drop policy if exists report_email_org_settings_upsert_owner on public.report_email_org_settings;
create policy "members can view report email org settings" on public.report_email_org_settings for select to authenticated using (is_org_member(org_id));
create policy "owners can manage report email org settings" on public.report_email_org_settings for all to authenticated using (has_org_role(org_id, ARRAY['owner'::text])) with check ((has_org_role(org_id, ARRAY['owner'::text]) AND updated_by_matches_actor(updated_by)));

alter table public.report_email_user_preferences alter column created_at set default now();
alter table public.report_email_user_preferences alter column updated_at set default now();
drop trigger if exists set_report_email_user_preferences_updated_at on public.report_email_user_preferences;
CREATE TRIGGER report_email_user_preferences_set_updated_at BEFORE UPDATE ON public.report_email_user_preferences FOR EACH ROW EXECUTE FUNCTION set_updated_at();
drop policy if exists report_email_user_preferences_insert_owner on public.report_email_user_preferences;
drop policy if exists report_email_user_preferences_select_member on public.report_email_user_preferences;
drop policy if exists report_email_user_preferences_update_owner on public.report_email_user_preferences;
create policy "members can view report email user preferences" on public.report_email_user_preferences for select to authenticated using (is_org_member(org_id));
create policy "owners can manage report email user preferences" on public.report_email_user_preferences for all to authenticated using (has_org_role(org_id, ARRAY['owner'::text])) with check ((has_org_role(org_id, ARRAY['owner'::text]) AND updated_by_matches_actor(updated_by)));

-- Source: scout-site@ef46714:supabase/migrations/202609280004_historical_scope_update_guards.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Scope checks that query parent deleted_at can become false after a valid
-- parent is soft-deleted. A CHECK re-runs for every metadata edit, preventing
-- account-attribution redaction of historical rows. Keep the same predicates
-- for inserts and scope-link changes; leave historical metadata edits possible.
create or replace function public.validate_historical_record_scope_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    scope_valid boolean;
begin
    -- UPDATE OF fires even if a client sends the same link values. Such an
    -- update is still a metadata edit and must not fail on an archived parent.
    if tg_op = 'UPDATE' then
        case tg_table_name
            when 'session_events' then
                if row(new.org_id, new.property_id, new.session_id)
                   is not distinct from row(old.org_id, old.property_id, old.session_id) then return new; end if;
            when 'session_snapshots' then
                if row(new.org_id, new.property_id, new.session_id)
                   is not distinct from row(old.org_id, old.property_id, old.session_id) then return new; end if;
            when 'report_packages', 'temporary_exports' then
                if row(new.org_id, new.property_id, new.session_id, new.snapshot_id)
                   is not distinct from row(old.org_id, old.property_id, old.session_id, old.snapshot_id) then return new; end if;
            when 'report_package_files' then
                if row(new.package_id, new.org_id, new.property_id, new.session_id, new.snapshot_id)
                   is not distinct from row(old.package_id, old.org_id, old.property_id, old.session_id, old.snapshot_id) then return new; end if;
            when 'observations' then
                if row(new.org_id, new.property_id, new.session_id,
                       new.first_seen_session_id, new.last_update_session_id,
                       new.resolved_session_id, new.shot_id)
                   is not distinct from row(old.org_id, old.property_id, old.session_id,
                       old.first_seen_session_id, old.last_update_session_id,
                       old.resolved_session_id, old.shot_id) then return new; end if;
            when 'observation_updates' then
                if row(new.org_id, new.property_id, new.observation_id, new.session_id, new.shot_id)
                   is not distinct from row(old.org_id, old.property_id, old.observation_id, old.session_id, old.shot_id) then return new; end if;
            when 'punchlist_activity' then
                if row(new.org_id, new.property_id, new.observation_id, new.shot_id)
                   is not distinct from row(old.org_id, old.property_id, old.observation_id, old.shot_id) then return new; end if;
        end case;
    end if;
    case tg_table_name
        when 'session_events' then
            scope_valid := public.session_event_insert_scope_valid(
                new.org_id, new.property_id, new.session_id
            );
        when 'session_snapshots' then
            scope_valid := public.session_snapshot_row_matches_parents(
                new.org_id, new.property_id, new.session_id
            );
        when 'report_packages' then
            scope_valid := public.report_artifact_row_matches_parents(
                new.org_id, new.property_id, new.session_id, new.snapshot_id
            );
        when 'temporary_exports' then
            scope_valid := public.report_artifact_row_matches_parents(
                new.org_id, new.property_id, new.session_id, new.snapshot_id
            );
        when 'report_package_files' then
            scope_valid := public.report_package_file_matches_package(
                new.package_id, new.org_id, new.property_id, new.session_id, new.snapshot_id
            );
        when 'observations' then
            scope_valid := public.observation_lineage_scope_valid(
                new.org_id, new.property_id, new.session_id,
                new.first_seen_session_id, new.last_update_session_id,
                new.resolved_session_id, new.shot_id
            );
        when 'observation_updates' then
            scope_valid := public.observation_update_scope_valid(
                new.org_id, new.property_id, new.observation_id,
                new.session_id, new.shot_id
            );
        when 'punchlist_activity' then
            scope_valid := public.punchlist_activity_scope_valid(
                new.org_id, new.property_id, new.observation_id, new.shot_id
            );
        else
            raise exception 'Unreviewed historical scope table: %', tg_table_name;
    end case;
    if scope_valid is false then
        raise exception 'Invalid % organization/property/session scope', tg_table_name;
    end if;
    return new;
end;
$$;

revoke all on function public.validate_historical_record_scope_change()
    from public, anon, authenticated;

alter table public.session_events
    drop constraint if exists session_events_scope_consistency_check;
drop trigger if exists validate_historical_scope on public.session_events;
create trigger validate_historical_scope
    before insert or update of org_id, property_id, session_id
    on public.session_events for each row
    execute function public.validate_historical_record_scope_change();

alter table public.session_snapshots
    drop constraint if exists session_snapshots_parent_match_check;
drop trigger if exists validate_historical_scope on public.session_snapshots;
create trigger validate_historical_scope
    before insert or update of org_id, property_id, session_id
    on public.session_snapshots for each row
    execute function public.validate_historical_record_scope_change();

alter table public.report_packages
    drop constraint if exists report_packages_parent_match_check;
drop trigger if exists validate_historical_scope on public.report_packages;
create trigger validate_historical_scope
    before insert or update of org_id, property_id, session_id, snapshot_id
    on public.report_packages for each row
    execute function public.validate_historical_record_scope_change();

alter table public.temporary_exports
    drop constraint if exists temporary_exports_parent_match_check;
drop trigger if exists validate_historical_scope on public.temporary_exports;
create trigger validate_historical_scope
    before insert or update of org_id, property_id, session_id, snapshot_id
    on public.temporary_exports for each row
    execute function public.validate_historical_record_scope_change();

alter table public.report_package_files
    drop constraint if exists report_package_files_package_match_check;
drop trigger if exists validate_historical_scope on public.report_package_files;
create trigger validate_historical_scope
    before insert or update of package_id, org_id, property_id, session_id, snapshot_id
    on public.report_package_files for each row
    execute function public.validate_historical_record_scope_change();

alter table public.observations
    drop constraint if exists observations_lineage_scope_check;
drop trigger if exists validate_historical_scope on public.observations;
create trigger validate_historical_scope
    before insert or update of org_id, property_id, session_id,
        first_seen_session_id, last_update_session_id, resolved_session_id, shot_id
    on public.observations for each row
    execute function public.validate_historical_record_scope_change();

alter table public.observation_updates
    drop constraint if exists observation_updates_scope_check;
drop trigger if exists validate_historical_scope on public.observation_updates;
create trigger validate_historical_scope
    before insert or update of org_id, property_id, observation_id, session_id, shot_id
    on public.observation_updates for each row
    execute function public.validate_historical_record_scope_change();

alter table public.punchlist_activity
    drop constraint if exists punchlist_activity_scope_check;
drop trigger if exists validate_historical_scope on public.punchlist_activity;
create trigger validate_historical_scope
    before insert or update of org_id, property_id, observation_id, shot_id
    on public.punchlist_activity for each row
    execute function public.validate_historical_record_scope_change();

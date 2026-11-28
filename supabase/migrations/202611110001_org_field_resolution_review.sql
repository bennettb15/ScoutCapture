-- Source: scout-site@ef46714:supabase/migrations/202611110001_org_field_resolution_review.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Keep the existing review workflow for every organization until an owner changes it.
alter table public.orgs
  add column if not exists require_review_for_field_resolutions boolean not null default true;

comment on column public.orgs.require_review_for_field_resolutions is
  'Whether a field-resolved issue waits for portal review before becoming final.';

-- The upload worker publishes its policy decision separately from a human approval.
alter table public.punchlist_activity
  drop constraint if exists punchlist_activity_type_check;

alter table public.punchlist_activity
  add constraint punchlist_activity_type_check
  check (activity_type in (
    'note_added', 'status_changed', 'priority_changed', 'due_date_changed',
    'trade_changed', 'completion_submitted', 'completion_approved',
    'completion_rejected', 'field_resolution_finalized'
  ));

create index if not exists idx_punchlist_activity_field_resolution
  on public.punchlist_activity (observation_id, created_at desc)
  where deleted_at is null and activity_type = 'field_resolution_finalized';

-- Only the service role can write the worker's finalization event.
drop policy if exists punchlist_activity_insert_owner_manager_field on public.punchlist_activity;
create policy punchlist_activity_insert_owner_manager_field
on public.punchlist_activity
for insert
to authenticated
with check (
  activity_type <> 'field_resolution_finalized'
  and public.has_org_role(org_id, array['owner', 'manager', 'field'])
  and public.has_observation_access(org_id, observation_id)
  and public.punchlist_activity_scope_valid(org_id, property_id, observation_id, shot_id)
  and public.updated_by_matches_actor(created_by)
);

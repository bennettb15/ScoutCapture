-- Hotfix for report package creation from completed sealed snapshots.
--
-- The report package worker derives deliverable parent fields from the sealed
-- session snapshot. This helper should use that same snapshot as the authority
-- instead of rechecking mutable live property/session state.

create or replace function public.report_artifact_row_matches_parents(
    target_org_id uuid,
    target_property_id uuid,
    target_session_id uuid,
    target_snapshot_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.session_snapshots snapshot
        where snapshot.id = target_snapshot_id
          and snapshot.org_id = target_org_id
          and snapshot.property_id = target_property_id
          and snapshot.session_id = target_session_id
          and snapshot.snapshot_kind = 'completed'
          and snapshot.is_sealed = true
          and snapshot.deleted_at is null
    );
$$;

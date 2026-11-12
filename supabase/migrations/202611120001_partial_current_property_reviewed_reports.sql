begin;

-- Permit a current-property report after the first review decision.
-- Remaining items retain their Pending Review status in the pinned snapshot.
create or replace function public.prepare_reviewed_report_request()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_session_id uuid;
    v_submissions jsonb;
    v_current jsonb;
begin
    if new.report_scope = 'current_property' then
        v_current := public.current_reviewed_report_state(new.org_id, new.property_id);
        if v_current->>'package_id' is null
           or v_current->>'package_id' <> new.source_package_id::text
           or v_current->>'state_hash' is distinct from new.current_state_hash
           or jsonb_array_length(v_current->'issue_states') = 0
           or jsonb_array_length(v_current->'review_outcomes') = 0
           or exists (
               select 1 from jsonb_array_elements(v_current->'issue_states') issue
               where coalesce(issue->>'status', '') not in ('active', 'pending_review', 'resolved')
           ) then
            raise exception 'Current property report inputs changed or are incomplete' using errcode = '23514';
        end if;
        new.current_issue_states := v_current->'issue_states';
        new.review_outcomes := v_current->'review_outcomes';
        return new;
    end if;

    select pkg.session_id, snapshot.manifest->'fieldResolutionSubmissions'
    into v_session_id, v_submissions
    from public.report_packages pkg
    join public.session_snapshots snapshot on snapshot.id = pkg.snapshot_id and snapshot.session_id = pkg.session_id
        and snapshot.org_id = pkg.org_id and snapshot.property_id = pkg.property_id
    join public.properties p on p.id = pkg.property_id and p.org_id = pkg.org_id
    where pkg.id = new.source_package_id and pkg.org_id = new.org_id and pkg.property_id = new.property_id
      and pkg.status = 'ready' and pkg.deleted_at is null and p.deleted_at is null
      and snapshot.is_sealed and snapshot.snapshot_kind = 'completed'
      and snapshot.session_status = 'completed' and snapshot.deleted_at is null
      and coalesce(pkg.manifest->>'report_variant', '') <> 'reviewed';
    if not found then
        raise exception 'Source must be a ready automatic report package for this property' using errcode = '23514';
    end if;

    if v_submissions is null then
        select coalesce(jsonb_agg(jsonb_build_object(
            'observation_id', legacy.observation_id,
            'shot_id', legacy.shot_id,
            'decision_activity_id', legacy.decision_activity_id,
            'status', legacy.status,
            'legacy', true
        ) order by legacy.shot_id), '[]'::jsonb)
        into new.review_outcomes
        from public.legacy_reviewed_report_outcomes(new.org_id, new.property_id, array[new.source_package_id]) legacy;

        if jsonb_array_length(new.review_outcomes) = 0
           or jsonb_path_exists(new.review_outcomes, '$[*] ? (@.status == null)') then
            raise exception 'All field resolutions in the source session must be reviewed' using errcode = '23514';
        end if;
        return new;
    end if;

    -- Pin the decision for each exact submission to the request. Future
    -- approvals, rejections, or captures cannot change a queued copy.
    select coalesce(jsonb_agg(jsonb_build_object(
        'observation_id', submitted.observation_id,
        'shot_id', submitted.shot_id,
        'submission_activity_id', submitted.id,
        'decision_activity_id', decision.id,
        'status', case decision.activity_type
            when 'completion_approved' then 'resolved'
            when 'completion_rejected' then 'active'
        end
    ) order by submitted.observation_id, submitted.shot_id), '[]'::jsonb)
    into new.review_outcomes
    from public.punchlist_activity submitted
    left join public.punchlist_activity decision
        on decision.field_resolution_submission_id = submitted.id
        and decision.org_id = submitted.org_id and decision.property_id = submitted.property_id
        and decision.observation_id = submitted.observation_id
        and decision.shot_id is not distinct from submitted.shot_id
        and decision.from_value = submitted.id::text and decision.deleted_at is null
    where submitted.org_id = new.org_id and submitted.property_id = new.property_id
      and submitted.activity_type = 'field_resolution_finalized' and submitted.deleted_at is null
      and submitted.from_value = v_session_id::text and submitted.to_value = 'pending_review'
      and v_submissions @> jsonb_build_array(jsonb_build_object(
          'activity_id', submitted.id, 'observation_id', submitted.observation_id,
          'shot_id', submitted.shot_id, 'status', 'pending_review'
      ));

    if jsonb_array_length(new.review_outcomes) = 0
       or jsonb_array_length(new.review_outcomes) <> jsonb_array_length(
           jsonb_path_query_array(v_submissions, '$[*] ? (@.status == "pending_review")')
       )
       or jsonb_path_exists(new.review_outcomes, '$[*] ? (@.status == null)') then
        raise exception 'All field resolutions in the source session must be reviewed' using errcode = '23514';
    end if;
    return new;
end;
$$;

commit;

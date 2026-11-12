begin;

alter table public.reviewed_report_requests
    add column report_scope text not null default 'visit'
        check (report_scope in ('visit', 'current_property')),
    add column current_state_hash text,
    add column current_issue_states jsonb;

create unique index reviewed_report_requests_current_state
    on public.reviewed_report_requests (source_package_id, current_state_hash)
    where report_scope = 'current_property' and status in ('queued', 'generating', 'ready');

create function public.current_reviewed_report_state(p_org_id uuid, p_property_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
    with sealed as (
        select snap.id, snap.session_id, snap.created_at, snap.manifest, s.completed_at
        from public.session_snapshots snap
        join public.sessions s on s.id = snap.session_id and s.org_id = snap.org_id and s.property_id = snap.property_id
        join public.properties p on p.id = snap.property_id and p.org_id = snap.org_id and p.deleted_at is null
        where snap.org_id = p_org_id and snap.property_id = p_property_id
          and snap.is_sealed and snap.snapshot_kind = 'completed' and snap.session_status = 'completed'
          and snap.deleted_at is null and s.is_sealed and s.status = 'completed' and s.deleted_at is null
          and s.completed_at is not null
    ), latest_snapshot as (
        select * from sealed order by completed_at desc, created_at desc, id desc limit 1
    ), latest_package as (
        select pkg.id, pkg.session_completed_at
        from latest_snapshot snap
        join public.report_packages pkg on pkg.snapshot_id = snap.id and pkg.session_id = snap.session_id
         and pkg.org_id = p_org_id and pkg.property_id = p_property_id
        where pkg.status = 'ready' and pkg.deleted_at is null and pkg.generation_trigger = 'session_completed'
          and coalesce(pkg.manifest->>'report_variant', '') <> 'reviewed'
          and exists (
              select 1 from public.report_package_files f
              where f.package_id = pkg.id and f.org_id = p_org_id and f.property_id = p_property_id
                and f.report_type in ('property_report', 'flagged_observations', 'flagged_comparison')
                and f.deleted_at is null and f.storage_deleted_at is null
              having count(distinct f.report_type) = 3
          )
        order by pkg.completed_at desc nulls last, pkg.id desc limit 1
    ), issues as (
        select id, coalesce(nullif(lower(btrim(status)), ''), 'unknown') as status
        from public.observations
        where org_id = p_org_id and property_id = p_property_id and deleted_at is null
    ), scoped_decisions as (
        select a.id, a.observation_id, a.shot_id, a.to_value, a.created_at, a.created_by,
               a.field_resolution_submission_id, a.from_value, a.legacy_field_review_verified
        from public.punchlist_activity a join issues i on i.id = a.observation_id
        where a.org_id = p_org_id and a.property_id = p_property_id and a.deleted_at is null
          and a.created_by is not null
          and ((a.activity_type = 'completion_approved' and a.to_value = 'resolved')
               or (a.activity_type = 'completion_rejected' and a.to_value = 'active'))
    ), modern as (
        select a.id, a.observation_id, a.shot_id, a.to_value, a.created_at,
               submitted.id as submission_activity_id, snap.id as snapshot_id, snap.session_id
        from scoped_decisions a join public.punchlist_activity submitted
          on submitted.id = a.field_resolution_submission_id and a.from_value = submitted.id::text
         and submitted.org_id = p_org_id and submitted.property_id = p_property_id
         and submitted.observation_id = a.observation_id and submitted.shot_id is not distinct from a.shot_id
         and submitted.activity_type = 'field_resolution_finalized' and submitted.to_value = 'pending_review'
         and submitted.deleted_at is null and a.created_at >= submitted.created_at
        join sealed snap on snap.session_id::text = submitted.from_value
         and snap.manifest->'fieldResolutionSubmissions' @> jsonb_build_array(jsonb_build_object(
            'activity_id', submitted.id, 'observation_id', submitted.observation_id,
            'shot_id', submitted.shot_id, 'status', 'pending_review'
         ))
    ), legacy as (
        select a.id, a.observation_id, a.shot_id, a.to_value, a.created_at,
               null::uuid as submission_activity_id, snap.id as snapshot_id, snap.session_id
        from scoped_decisions a
        join public.shots sh on sh.id = a.shot_id and sh.issue_id = a.observation_id
         and sh.org_id = p_org_id and sh.property_id = p_property_id
         and sh.capture_kind = 'resolved_capture' and sh.upload_state = 'uploaded' and sh.deleted_at is null
        join sealed snap on snap.session_id = sh.session_id
         and snap.manifest->'fieldResolutionSubmissions' is null
         and snap.manifest->'media' @> jsonb_build_array(jsonb_build_object('id', sh.id))
         and a.created_at >= snap.created_at
        where a.field_resolution_submission_id is null and a.from_value = 'pending_review'
          and (a.legacy_field_review_verified or exists (
              select 1 from public.org_memberships m
              where m.org_id = p_org_id and m.user_id = a.created_by and m.deleted_at is null
                and m.role in ('owner', 'manager', 'viewer')
                and (m.role = 'owner' or m.access_scope = 'org' or exists (
                    select 1 from public.property_access_grants g
                    where g.org_id = p_org_id and g.property_id = p_property_id
                      and g.user_id = m.user_id and g.deleted_at is null
                ))
          ))
    ), decisions as (
        select distinct on (d.observation_id, d.shot_id) d.*
        from (select * from modern union all select * from legacy) d
        join sealed snap on snap.id = d.snapshot_id
        order by d.observation_id, d.shot_id, d.created_at desc, d.id desc, snap.created_at desc, snap.id desc
    ), state as (
        select jsonb_build_object(
            'package_id', (select id from latest_package),
            'session_completed_at', (select session_completed_at from latest_package),
            'unresolved_count', (select count(*) from issues where status not in ('active', 'resolved')),
            'issue_states', (select coalesce(jsonb_agg(jsonb_build_object(
                'observation_id', id, 'status', status
            ) order by id), '[]'::jsonb) from issues),
            'review_outcomes', (select coalesce(jsonb_agg(jsonb_build_object(
                'observation_id', observation_id, 'shot_id', shot_id, 'status', to_value,
                'submission_activity_id', submission_activity_id, 'decision_activity_id', id,
                'snapshot_id', snapshot_id, 'session_id', session_id
            ) order by observation_id, shot_id), '[]'::jsonb) from decisions)
        ) as payload
    )
    select payload || jsonb_build_object('state_hash', md5(payload::text)) from state;
$$;

revoke all on function public.current_reviewed_report_state(uuid,uuid) from public, anon, authenticated;
grant execute on function public.current_reviewed_report_state(uuid,uuid) to service_role;

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
           or (v_current->>'unresolved_count')::integer <> 0
           or jsonb_array_length(v_current->'issue_states') = 0 then
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

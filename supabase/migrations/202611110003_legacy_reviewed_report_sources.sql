begin;

-- Older activity policies let field users insert an unlinked review event.
-- Record server provenance for decisions made through the portal from now on.
alter table public.punchlist_activity
    add column legacy_field_review_verified boolean not null default false;

create function public.stamp_legacy_field_review_provenance() returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.legacy_field_review_verified :=
        current_user = 'service_role'
        and new.activity_type in ('completion_approved', 'completion_rejected')
        and coalesce(new.from_value, '') = 'pending_review'
        and new.field_resolution_submission_id is null;
    return new;
end;
$$;

create trigger stamp_legacy_field_review_provenance
    before insert on public.punchlist_activity
    for each row execute function public.stamp_legacy_field_review_provenance();

-- Resolve legacy field decisions only within a ready package's sealed visit.
-- The worker independently checks the complete set against the sealed payload.
create function public.legacy_reviewed_report_outcomes(
    p_org_id uuid, p_property_id uuid, p_package_ids uuid[]
) returns table(package_id uuid, observation_id uuid, shot_id uuid, decision_activity_id uuid, status text)
language sql stable
set search_path = ''
as $$
    with captures as (
        select pkg.id as package_id, sh.issue_id as observation_id, sh.id as shot_id, sh.issue_status,
               decision.id as decision_activity_id, decision.to_value as status
        from public.report_packages pkg
        join public.session_snapshots snap
          on snap.id = pkg.snapshot_id and snap.org_id = pkg.org_id
         and snap.property_id = pkg.property_id and snap.session_id = pkg.session_id
        join public.shots sh
          on sh.org_id = pkg.org_id and sh.property_id = pkg.property_id and sh.session_id = pkg.session_id
         and snap.manifest->'media' @> jsonb_build_array(jsonb_build_object('id', sh.id))
        join public.observations ob
          on ob.id = sh.issue_id and ob.org_id = sh.org_id and ob.property_id = sh.property_id
         and ob.deleted_at is null
        left join lateral (
            select a.id, a.to_value
            from public.punchlist_activity a
            where a.org_id = sh.org_id and a.property_id = sh.property_id
              and a.observation_id = sh.issue_id and a.shot_id = sh.id and a.deleted_at is null
              and a.field_resolution_submission_id is null and a.from_value = 'pending_review'
              and a.created_by is not null and a.created_at >= snap.created_at
              and (a.legacy_field_review_verified or exists (
                  select 1 from public.org_memberships m
                  where m.org_id = a.org_id and m.user_id = a.created_by and m.deleted_at is null
                    and m.role in ('owner', 'manager', 'viewer')
                    and (m.role = 'owner' or m.access_scope = 'org' or exists (
                        select 1 from public.property_access_grants g
                        where g.org_id = a.org_id and g.property_id = a.property_id
                          and g.user_id = m.user_id and g.deleted_at is null
                    ))
              ))
              and ((a.activity_type = 'completion_approved' and a.to_value = 'resolved')
                   or (a.activity_type = 'completion_rejected' and a.to_value = 'active'))
            order by a.created_at desc, a.id desc
            limit 1
        ) decision on true
        where pkg.id = any(p_package_ids) and pkg.org_id = p_org_id and pkg.property_id = p_property_id
          and pkg.status = 'ready' and pkg.deleted_at is null
          and coalesce(pkg.manifest->>'report_variant', '') <> 'reviewed'
          and snap.is_sealed and snap.snapshot_kind = 'completed' and snap.session_status = 'completed'
          and snap.deleted_at is null and snap.trigger = 'fast_lane_report_handoff'
          and snap.manifest->'fieldResolutionSubmissions' is null
          and sh.capture_kind = 'resolved_capture' and sh.upload_state = 'uploaded' and sh.deleted_at is null
          and exists (
              select 1 from public.report_package_files f
              where f.package_id = pkg.id and f.org_id = pkg.org_id and f.property_id = pkg.property_id
                and f.report_type in ('property_report', 'flagged_observations', 'flagged_comparison')
                and f.deleted_at is null and f.storage_deleted_at is null
              having count(distinct f.report_type) = 3
          )
          and not exists (
              select 1 from public.punchlist_activity a
              where a.org_id = pkg.org_id and a.property_id = pkg.property_id
                and a.activity_type = 'field_resolution_finalized' and a.from_value = pkg.session_id::text
          )
    )
    select c.package_id, c.observation_id, c.shot_id, c.decision_activity_id, c.status
    from captures c
    where exists (
        select 1 from captures evidence
        where evidence.package_id = c.package_id
          and (evidence.issue_status = 'pending_review' or evidence.decision_activity_id is not null)
    );
$$;

revoke all on function public.legacy_reviewed_report_outcomes(uuid,uuid,uuid[]) from public, anon, authenticated;
grant execute on function public.legacy_reviewed_report_outcomes(uuid,uuid,uuid[]) to service_role;

create or replace function public.prepare_reviewed_report_request() returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_session_id uuid;
    v_submissions jsonb;
begin
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

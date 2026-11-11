-- Depends on Scout Website's 202611110001_org_field_resolution_review.sql.
begin;

create unique index field_resolution_finalized_submission_key
    on public.punchlist_activity (org_id, property_id, observation_id, from_value, shot_id)
    nulls not distinct
    where activity_type = 'field_resolution_finalized' and deleted_at is null;

-- An observation may retain its original shot link when it is resolved in
-- a later visit. Activity may reference that visit's scoped resolution photo.
create or replace function public.punchlist_activity_scope_valid(
    target_org_id uuid,
    target_property_id uuid,
    target_observation_id uuid,
    target_shot_id uuid
) returns boolean
language sql stable security definer
set search_path = ''
as $$
    select public.property_belongs_to_org(target_property_id, target_org_id)
        and exists (
            select 1 from public.observations o
            where o.id = target_observation_id and o.org_id = target_org_id
              and o.property_id = target_property_id and o.deleted_at is null
              and (target_shot_id is null or o.shot_id = target_shot_id or exists (
                  select 1 from public.shots sh
                  where sh.id = target_shot_id and sh.issue_id = o.id
                    and sh.org_id = target_org_id and sh.property_id = target_property_id
                    and sh.capture_kind = 'resolved_capture' and sh.deleted_at is null
              ))
        );
$$;

create function public.finalize_field_resolution_upload(
    p_org_id uuid,
    p_property_id uuid,
    p_session_id uuid
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
    v_requires_review boolean;
    v_issue record;
    v_outcome text;
    v_event_at timestamptz;
    v_now timestamptz;
begin
    -- Serialize both foreground and background attempts for this sealed session.
    perform 1 from public.sessions s
    join public.properties p on p.id = s.property_id and p.org_id = s.org_id
    where s.id = p_session_id and s.org_id = p_org_id and s.property_id = p_property_id
      and s.status = 'completed' and s.is_sealed and s.completed_at is not null
      and s.deleted_at is null and p.deleted_at is null
    for update of s;
    if not found then
        raise exception 'Field resolution upload does not match a sealed session';
    end if;

    select o.require_review_for_field_resolutions into strict v_requires_review
    from public.orgs o where o.id = p_org_id for share;

    for v_issue in
        select o.id, o.updated_at, evidence.id as shot_id
        from public.observations o
        left join lateral (
            select sh.id, sh.upload_state, sh.issue_status
            from public.shots sh
            where sh.issue_id = o.id and sh.org_id = p_org_id
              and sh.property_id = p_property_id and sh.session_id = p_session_id
              and sh.capture_kind = 'resolved_capture' and sh.deleted_at is null
              and coalesce(sh.lifecycle_state, 'active') = 'active'
            order by (sh.id is not distinct from o.shot_id) desc,
                     coalesce(sh.captured_at, sh.created_at) desc, sh.id desc
            limit 1 for update
        ) evidence on true
        where o.org_id = p_org_id and o.property_id = p_property_id
          and coalesce(o.last_update_session_id, o.session_id) = p_session_id
          and o.status = 'pending_review' and o.deleted_at is null
          and (
              (evidence.id is not null and evidence.upload_state = 'uploaded'
                  and evidence.issue_status in ('pending_review', 'resolved'))
              or (evidence.id is null and not exists (
                  select 1 from public.shots current_link
                  where current_link.session_id = p_session_id and current_link.org_id = p_org_id
                    and current_link.property_id = p_property_id
                    and (current_link.id = o.shot_id
                      or (current_link.issue_id = o.id and current_link.capture_kind = 'resolved_capture'))
              ))
          )
        order by o.id
        for update of o
    loop
        select a.to_value, a.created_at into v_outcome, v_event_at
        from public.punchlist_activity a
        where a.org_id = p_org_id and a.property_id = p_property_id
          and a.observation_id = v_issue.id and a.shot_id is not distinct from v_issue.shot_id
          and a.activity_type = 'field_resolution_finalized' and a.from_value = p_session_id::text
          and a.deleted_at is null;

        -- The website may publish its review event just before it syncs the
        -- observation. Do not overwrite that decision if an upload is retried.
        if exists (
            select 1 from public.punchlist_activity a
            where a.org_id = p_org_id and a.property_id = p_property_id
              and a.observation_id = v_issue.id and a.shot_id is not distinct from v_issue.shot_id
              and a.activity_type in ('completion_approved', 'completion_rejected')
              and a.deleted_at is null
              and a.created_at >= coalesce(v_event_at, v_issue.updated_at)
        ) then
            continue;
        end if;

        v_now := clock_timestamp();
        if v_outcome is null then
            v_outcome := case when v_requires_review then 'pending_review' else 'resolved' end;
            insert into public.punchlist_activity
                (org_id, property_id, observation_id, shot_id, activity_type, from_value, to_value, created_at)
            values
                (p_org_id, p_property_id, v_issue.id, v_issue.shot_id, 'field_resolution_finalized',
                 p_session_id::text, v_outcome, v_now);
        end if;

        update public.observations o
        set status = v_outcome,
            resolved_session_id = case when v_outcome = 'resolved' then p_session_id end,
            resolved_at = case when v_outcome = 'resolved' then coalesce(v_event_at, v_now) end
        where o.id = v_issue.id and (
            o.status is distinct from v_outcome
            or (v_outcome = 'pending_review' and (o.resolved_at is not null or o.resolved_session_id is not null))
        );

        update public.shots sh
        set issue_status = v_outcome
        where sh.id = v_issue.shot_id and sh.issue_id = v_issue.id
          and sh.org_id = p_org_id and sh.property_id = p_property_id and sh.session_id = p_session_id
          and sh.deleted_at is null and sh.upload_state = 'uploaded' and sh.capture_kind = 'resolved_capture'
          and sh.issue_status in ('pending_review', 'resolved') and sh.issue_status <> v_outcome;
    end loop;

    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'observation_id', a.observation_id, 'shot_id', a.shot_id, 'status', a.to_value
        ) order by a.observation_id, a.shot_id)
        from public.punchlist_activity a
        where a.org_id = p_org_id and a.property_id = p_property_id and a.from_value = p_session_id::text
          and a.activity_type = 'field_resolution_finalized' and a.deleted_at is null
    ), '[]'::jsonb);
end;
$$;

revoke all on function public.finalize_field_resolution_upload(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.finalize_field_resolution_upload(uuid, uuid, uuid) to service_role;

create table public.reviewed_report_requests (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null references public.orgs(id) on delete cascade,
    property_id uuid not null references public.properties(id) on delete cascade,
    requested_by uuid not null,
    source_package_id uuid not null references public.report_packages(id) on delete cascade,
    status text not null default 'queued' check (status in ('queued', 'generating', 'ready', 'failed')),
    progress_step text not null default 'queued' check (
        progress_step in ('queued', 'validating', 'preparing_photos', 'rendering', 'uploading', 'ready', 'failed')
    ),
    result_package_id uuid references public.report_packages(id) on delete cascade,
    requested_at timestamptz not null default now(),
    locked_at timestamptz,
    completed_at timestamptz,
    last_error text,
    review_outcomes jsonb not null default '[]'::jsonb,
    check ((status = 'ready') = (result_package_id is not null))
);

create index reviewed_report_requests_queue on public.reviewed_report_requests (status, requested_at);
create unique index reviewed_report_requests_active_source
    on public.reviewed_report_requests (source_package_id)
    where status in ('queued', 'generating');
alter table public.reviewed_report_requests enable row level security;
revoke all on public.reviewed_report_requests from public, anon, authenticated;
grant select, insert, update on public.reviewed_report_requests to service_role;

create function public.prepare_reviewed_report_request() returns trigger
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

    -- Pin the decision for each exact submission to the request. Future
    -- approvals, rejections, or captures cannot change a queued copy.
    select coalesce(jsonb_agg(jsonb_build_object(
        'observation_id', submitted.observation_id,
        'shot_id', submitted.shot_id,
        'submission_activity_id', submitted.id,
        'decision_activity_id', decision.id,
        'status', decision.status
    ) order by submitted.observation_id, submitted.shot_id), '[]'::jsonb)
    into new.review_outcomes
    from public.punchlist_activity submitted
    left join lateral (
        select reviewed.id,
            case reviewed.activity_type when 'completion_approved' then 'resolved' else 'active' end as status
        from public.punchlist_activity reviewed
        where reviewed.org_id = submitted.org_id and reviewed.property_id = submitted.property_id
          and reviewed.observation_id = submitted.observation_id
          and reviewed.shot_id is not distinct from submitted.shot_id
          and reviewed.activity_type in ('completion_approved', 'completion_rejected')
          and reviewed.deleted_at is null and reviewed.created_at >= submitted.created_at
          and not exists (
              select 1 from public.punchlist_activity newer
              where newer.org_id = submitted.org_id and newer.property_id = submitted.property_id
                and newer.observation_id = submitted.observation_id
                and newer.shot_id is not distinct from submitted.shot_id
                and newer.activity_type = 'field_resolution_finalized' and newer.deleted_at is null
                and newer.created_at > submitted.created_at and newer.created_at <= reviewed.created_at
          )
        order by reviewed.created_at desc, reviewed.id desc
        limit 1
    ) decision on true
    where submitted.org_id = new.org_id and submitted.property_id = new.property_id
      and submitted.activity_type = 'field_resolution_finalized' and submitted.deleted_at is null
      and submitted.from_value = v_session_id::text and submitted.to_value = 'pending_review'
      and v_submissions @> jsonb_build_array(jsonb_build_object(
          'observation_id', submitted.observation_id, 'shot_id', submitted.shot_id, 'status', 'pending_review'
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

create trigger prepare_reviewed_report_request before insert on public.reviewed_report_requests
    for each row execute function public.prepare_reviewed_report_request();

commit;

-- Depends on Scout Website's 202611110001_org_field_resolution_review.sql.
begin;

alter table public.punchlist_activity
    add column field_resolution_submission_id uuid references public.punchlist_activity(id) on delete set null,
    add constraint field_resolution_decision_type_check check (
        field_resolution_submission_id is null or activity_type in ('completion_approved', 'completion_rejected')
    );

create unique index field_resolution_decision_submission_key
    on public.punchlist_activity (field_resolution_submission_id)
    where field_resolution_submission_id is not null and deleted_at is null;

create policy punchlist_activity_linked_field_review_service_only
    on public.punchlist_activity as restrictive for insert to authenticated
    with check (field_resolution_submission_id is null);

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
    v_submission_id uuid;
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
        select a.id, a.to_value, a.created_at into v_submission_id, v_outcome, v_event_at
        from public.punchlist_activity a
        where a.org_id = p_org_id and a.property_id = p_property_id
          and a.observation_id = v_issue.id and a.shot_id is not distinct from v_issue.shot_id
          and a.activity_type = 'field_resolution_finalized' and a.from_value = p_session_id::text
          and a.deleted_at is null;

        -- A linked decision is specific to this upload, even when neither
        -- the current nor a previous submission has a photo.
        if exists (
            select 1 from public.punchlist_activity a
            where a.org_id = p_org_id and a.property_id = p_property_id
              and a.observation_id = v_issue.id
              and a.activity_type in ('completion_approved', 'completion_rejected')
              and a.deleted_at is null
              and (
                  a.field_resolution_submission_id = v_submission_id
                  or (a.field_resolution_submission_id is null and a.shot_id = v_issue.shot_id
                      and a.created_at >= coalesce(v_event_at, v_issue.updated_at))
              )
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
            'activity_id', a.id, 'observation_id', a.observation_id,
            'shot_id', a.shot_id, 'status', a.to_value
        ) order by a.observation_id, a.shot_id)
        from public.punchlist_activity a
        where a.org_id = p_org_id and a.property_id = p_property_id and a.from_value = p_session_id::text
          and a.activity_type = 'field_resolution_finalized' and a.deleted_at is null
    ), '[]'::jsonb);
end;
$$;

revoke all on function public.finalize_field_resolution_upload(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.finalize_field_resolution_upload(uuid, uuid, uuid) to service_role;

create function public.review_field_resolution_submission(
    p_submission_activity_id uuid,
    p_reviewer_id uuid,
    p_action text,
    p_note text default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
    v_submission public.punchlist_activity%rowtype;
    v_decision public.punchlist_activity%rowtype;
    v_observation public.observations%rowtype;
    v_shot public.shots%rowtype;
    v_session_id uuid;
    v_latest_activity_id uuid;
    v_decision_type text;
    v_status text;
    v_storage_prefix text;
    v_now timestamptz;
begin
    if p_reviewer_id is null or p_action is null or p_action not in ('approve', 'reject')
       or char_length(btrim(p_note)) > 1000 then
        raise exception 'Invalid field resolution review' using errcode = '23514';
    end if;
    v_decision_type := case p_action when 'approve' then 'completion_approved' else 'completion_rejected' end;
    v_status := case p_action when 'approve' then 'resolved' else 'active' end;

    select a.* into v_submission
    from public.punchlist_activity a
    where a.id = p_submission_activity_id and a.activity_type = 'field_resolution_finalized'
      and a.deleted_at is null;
    if not found then
        raise exception 'Field resolution submission not found' using errcode = 'P0002';
    end if;
    if v_submission.to_value is distinct from 'pending_review' then
        raise exception 'Field resolution submission did not require review' using errcode = '23514';
    end if;

    v_session_id := v_submission.from_value::uuid;
    -- Use the same session lock as upload finalization before locking the issue
    -- or its photo. Repeated reviews and upload retries share that ordering.
    perform 1 from public.sessions s
    join public.properties p on p.id = s.property_id and p.org_id = s.org_id
    where s.id = v_session_id and s.org_id = v_submission.org_id and s.property_id = v_submission.property_id
      and s.status = 'completed' and s.is_sealed and s.deleted_at is null and p.deleted_at is null
    for update of s;
    if not found then
        raise exception 'Field resolution submission session is unavailable' using errcode = '23514';
    end if;

    select o.* into v_observation
    from public.observations o
    where o.id = v_submission.observation_id and o.org_id = v_submission.org_id
      and o.property_id = v_submission.property_id and o.deleted_at is null
    for update;
    if not found then
        raise exception 'Field resolution observation is unavailable' using errcode = '23514';
    end if;

    select a.* into v_decision
    from public.punchlist_activity a
    where a.field_resolution_submission_id = v_submission.id
      and a.org_id = v_submission.org_id and a.property_id = v_submission.property_id
      and a.observation_id = v_submission.observation_id
      and a.shot_id is not distinct from v_submission.shot_id and a.deleted_at is null;
    if found then
        if v_decision.activity_type <> v_decision_type then
            raise exception 'Field resolution submission already has a different decision' using errcode = '23514';
        end if;
        return jsonb_build_object('status', v_decision.to_value, 'activity', to_jsonb(v_decision));
    end if;

    select a.id into v_latest_activity_id
    from public.punchlist_activity a
    where a.org_id = v_submission.org_id and a.property_id = v_submission.property_id
      and a.observation_id = v_submission.observation_id and a.deleted_at is null
      and a.activity_type in ('field_resolution_finalized', 'status_changed', 'completion_submitted',
                              'completion_approved', 'completion_rejected')
    order by a.created_at desc, a.id desc
    limit 1;
    if v_latest_activity_id is distinct from v_submission.id
       or v_observation.status is distinct from 'pending_review'
       or coalesce(v_observation.last_update_session_id, v_observation.session_id) is distinct from v_session_id then
        raise exception 'Field resolution submission is no longer pending review' using errcode = '23514';
    end if;

    if v_submission.shot_id is not null then
        select sh.* into v_shot from public.shots sh
        where sh.id = v_submission.shot_id and sh.org_id = v_submission.org_id
          and sh.property_id = v_submission.property_id and sh.issue_id = v_submission.observation_id
          and sh.session_id = v_session_id and sh.capture_kind = 'resolved_capture'
          and sh.deleted_at is null and coalesce(sh.lifecycle_state, 'active') = 'active'
        for update;
        if not found then
            raise exception 'Field resolution photo is unavailable' using errcode = '23514';
        end if;
        v_storage_prefix := format('sessions/%s/shots/%s/', v_session_id, v_shot.id);
    end if;
    if p_action = 'approve' and (v_shot.id is null or v_shot.upload_state is distinct from 'uploaded'
        or not coalesce(starts_with(v_shot.storage_path, v_storage_prefix)
                        and length(v_shot.storage_path) > length(v_storage_prefix), false)) then
        raise exception 'Approval requires an uploaded completion photo' using errcode = '23514';
    end if;

    v_now := clock_timestamp();
    insert into public.punchlist_activity (
        org_id, property_id, observation_id, shot_id, activity_type, from_value, to_value,
        note, created_by, created_at, field_resolution_submission_id
    ) values (
        v_submission.org_id, v_submission.property_id, v_submission.observation_id, v_submission.shot_id,
        v_decision_type, v_submission.id::text, v_status, nullif(btrim(p_note), ''), p_reviewer_id, v_now, v_submission.id
    ) returning * into v_decision;

    update public.observations
    set status = v_status,
        resolved_session_id = case when v_status = 'resolved' then v_session_id end,
        resolved_at = case when v_status = 'resolved' then v_now end,
        updated_by = p_reviewer_id
    where id = v_observation.id;
    update public.shots set issue_status = v_status where id = v_shot.id;

    return jsonb_build_object('status', v_status, 'activity', to_jsonb(v_decision));
end;
$$;

revoke all on function public.review_field_resolution_submission(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.review_field_resolution_submission(uuid, uuid, text, text) to service_role;

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

create trigger prepare_reviewed_report_request before insert on public.reviewed_report_requests
    for each row execute function public.prepare_reviewed_report_request();

commit;

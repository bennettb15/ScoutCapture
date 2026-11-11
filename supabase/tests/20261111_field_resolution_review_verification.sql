-- Run after the Website activity migrations and the ScoutCapture worker migration.
begin;

do $$
declare
    reviewer_id uuid := gen_random_uuid();
    org_id uuid := gen_random_uuid();
    property_id uuid := gen_random_uuid();
    original_session_id uuid := gen_random_uuid();
    review_session_id uuid := gen_random_uuid();
    checklist_issue_id uuid := gen_random_uuid();
    photo_issue_id uuid := gen_random_uuid();
    checklist_original_id uuid := gen_random_uuid();
    photo_original_id uuid := gen_random_uuid();
    resolution_shot_id uuid := gen_random_uuid();
    prior_portal_id uuid := gen_random_uuid();
    prior_field_id uuid := gen_random_uuid();
    snapshot_id uuid := gen_random_uuid();
    source_package_id uuid := gen_random_uuid();
    test_time timestamptz := now();
    submissions jsonb;
    checklist_submission_id uuid;
    photo_submission_id uuid;
    checklist_decision jsonb;
    photo_decision jsonb;
    request_outcomes jsonb;
    wrong_shot_decision_id uuid := gen_random_uuid();
    unlinked_decision_id uuid := gen_random_uuid();
begin
    assert not has_function_privilege('authenticated',
        'public.review_field_resolution_submission(uuid,uuid,text,text)', 'EXECUTE');
    assert has_function_privilege('service_role',
        'public.review_field_resolution_submission(uuid,uuid,text,text)', 'EXECUTE');

    insert into auth.users (id, aud, role, email, created_at, updated_at)
    values (reviewer_id, 'authenticated', 'authenticated', reviewer_id || '@example.test', test_time, test_time);
    insert into public.users_profile (id, email) values (reviewer_id, reviewer_id || '@example.test')
    on conflict (id) do nothing;

    insert into public.orgs (id, name, require_review_for_field_resolutions)
    values (org_id, 'Field review test organization', true);
    insert into public.properties (id, org_id, name)
    values (property_id, org_id, 'Field review test property');
    insert into public.sessions (id, org_id, property_id, status, is_sealed, started_at, completed_at)
    values (original_session_id, org_id, property_id, 'completed', true, test_time - interval '2 days', test_time - interval '2 days'),
           (review_session_id, org_id, property_id, 'completed', true, test_time - interval '1 day', test_time);

    insert into public.shots (id, org_id, property_id, session_id, issue_id, capture_kind, issue_status,
                             upload_state, storage_bucket, storage_path)
    values
        (checklist_original_id, org_id, property_id, original_session_id, checklist_issue_id, 'captured', 'active',
         'uploaded', 'scoutcapture-originals', format('sessions/%s/shots/%s/original.jpg', original_session_id, checklist_original_id)),
        (photo_original_id, org_id, property_id, original_session_id, photo_issue_id, 'captured', 'active',
         'uploaded', 'scoutcapture-originals', format('sessions/%s/shots/%s/original.jpg', original_session_id, photo_original_id)),
        (resolution_shot_id, org_id, property_id, review_session_id, photo_issue_id, 'resolved_capture', 'pending_review',
         'uploaded', 'scoutcapture-originals', format('sessions/%s/shots/%s/current.jpg', review_session_id, resolution_shot_id));
    insert into public.observations (id, org_id, property_id, session_id, last_update_session_id, shot_id, status)
    values (checklist_issue_id, org_id, property_id, original_session_id, review_session_id, checklist_original_id, 'pending_review'),
           (photo_issue_id, org_id, property_id, original_session_id, review_session_id, photo_original_id, 'pending_review');

    insert into public.punchlist_activity
        (id, org_id, property_id, observation_id, shot_id, activity_type, from_value, to_value,
         storage_bucket, storage_path, filename, mime_type, byte_size, created_by, created_at)
    values (prior_portal_id, org_id, property_id, photo_issue_id, photo_original_id, 'completion_submitted',
            prior_portal_id::text, 'pending_review', 'test-uploads', 'old.jpg', 'old.jpg', 'image/jpeg', 10,
            reviewer_id, test_time - interval '2 days');
    insert into public.punchlist_activity
        (org_id, property_id, observation_id, shot_id, activity_type, from_value, to_value, created_by, created_at)
    values (org_id, property_id, photo_issue_id, photo_original_id, 'completion_rejected', prior_portal_id::text,
            'active', reviewer_id, test_time - interval '36 hours');
    insert into public.punchlist_activity
        (id, org_id, property_id, observation_id, activity_type, from_value, to_value, created_at)
    values (prior_field_id, org_id, property_id, checklist_issue_id, 'field_resolution_finalized',
            original_session_id::text, 'pending_review', test_time - interval '2 days');

    submissions := public.finalize_field_resolution_upload(org_id, property_id, review_session_id);
    assert jsonb_array_length(submissions) = 2;
    select (value->>'activity_id')::uuid into strict checklist_submission_id
    from jsonb_array_elements(submissions) where value->>'observation_id' = checklist_issue_id::text;
    select (value->>'activity_id')::uuid into strict photo_submission_id
    from jsonb_array_elements(submissions) where value->>'observation_id' = photo_issue_id::text;

    insert into public.session_snapshots (
        id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
        session_status, is_sealed, payload_storage_bucket, payload_storage_path, payload_byte_size,
        raw_session_json_sha256, snapshot_payload_sha256, manifest
    ) values (
        snapshot_id, org_id, property_id, review_session_id, 'completed', 1, 'fast_lane_report_handoff',
        'completed', true, 'scoutcapture-session-snapshots',
        public.session_snapshot_expected_storage_path(org_id, property_id, review_session_id, 'completed', snapshot_id),
        1, repeat('0', 64), repeat('1', 64), jsonb_build_object('fieldResolutionSubmissions', submissions)
    );
    insert into public.report_packages
        (id, org_id, property_id, session_id, snapshot_id, status, idempotency_key, session_completed_at, renderer_version)
    values (source_package_id, org_id, property_id, review_session_id, snapshot_id, 'ready',
            'field-review-test:' || snapshot_id, test_time, 'test');

    begin
        perform public.review_field_resolution_submission(prior_field_id, reviewer_id, 'reject');
        raise exception 'Accepted a superseded field submission';
    exception when check_violation then null;
    end;
    begin
        perform public.review_field_resolution_submission(prior_portal_id, reviewer_id, 'approve');
        raise exception 'Accepted a portal activity as a field submission';
    exception when no_data_found then null;
    end;
    begin
        perform public.review_field_resolution_submission(checklist_submission_id, reviewer_id, 'approve');
        raise exception 'Approved a field resolution without a completion photo';
    exception when check_violation then null;
    end;

    photo_decision := public.review_field_resolution_submission(photo_submission_id, reviewer_id, 'approve');
    assert photo_decision->>'status' = 'resolved';
    assert photo_decision#>>'{activity,shot_id}' = resolution_shot_id::text;
    assert photo_decision#>>'{activity,from_value}' = photo_submission_id::text;
    assert photo_decision#>>'{activity,created_by}' = reviewer_id::text;
    assert (select status = 'resolved' and resolved_session_id = review_session_id and shot_id = photo_original_id
            from public.observations where id = photo_issue_id);
    assert (select issue_status = 'resolved' from public.shots where id = resolution_shot_id);

    -- The old route could reject the original photo. Even a matching
    -- unlinked activity cannot satisfy the field submission's review.
    insert into public.punchlist_activity
        (id, org_id, property_id, observation_id, shot_id, activity_type, from_value, to_value, created_by, created_at)
    values (wrong_shot_decision_id, org_id, property_id, checklist_issue_id, checklist_original_id,
            'completion_rejected', 'pending_review', 'active', reviewer_id, clock_timestamp()),
           (unlinked_decision_id, org_id, property_id, checklist_issue_id, null,
            'completion_rejected', checklist_submission_id::text, 'active', reviewer_id, clock_timestamp());
    begin
        insert into public.reviewed_report_requests (org_id, property_id, requested_by, source_package_id)
        values (org_id, property_id, reviewer_id, source_package_id);
        raise exception 'Generated reports while the checklist submission was pending';
    exception when check_violation then null;
    end;
    delete from public.punchlist_activity where id in (wrong_shot_decision_id, unlinked_decision_id);

    checklist_decision := public.review_field_resolution_submission(checklist_submission_id, reviewer_id, 'reject', '  Needs a photo  ');
    assert checklist_decision->>'status' = 'active';
    assert checklist_decision#>'{activity,shot_id}' = 'null'::jsonb;
    assert checklist_decision#>>'{activity,field_resolution_submission_id}' = checklist_submission_id::text;
    assert checklist_decision#>>'{activity,note}' = 'Needs a photo';
    assert (select status = 'active' and shot_id = checklist_original_id
            from public.observations where id = checklist_issue_id);
    assert (select count(*) = 2 and bool_and(issue_status = 'active') from public.shots
            where id in (checklist_original_id, photo_original_id));

    assert public.review_field_resolution_submission(checklist_submission_id, reviewer_id, 'reject') = checklist_decision;
    begin
        perform public.review_field_resolution_submission(photo_submission_id, reviewer_id, 'reject');
        raise exception 'Replaced an existing field review decision';
    exception when check_violation then null;
    end;
    assert public.finalize_field_resolution_upload(org_id, property_id, review_session_id) = submissions;

    insert into public.reviewed_report_requests (org_id, property_id, requested_by, source_package_id)
    values (org_id, property_id, reviewer_id, source_package_id) returning review_outcomes into request_outcomes;
    assert jsonb_array_length(request_outcomes) = 2;
    assert request_outcomes @> jsonb_build_array(jsonb_build_object(
        'submission_activity_id', checklist_submission_id,
        'decision_activity_id', checklist_decision#>>'{activity,id}',
        'shot_id', null, 'status', 'active'
    ));
    assert request_outcomes @> jsonb_build_array(jsonb_build_object(
        'submission_activity_id', photo_submission_id,
        'decision_activity_id', photo_decision#>>'{activity,id}',
        'shot_id', resolution_shot_id, 'status', 'resolved'
    ));
    raise notice 'Field review kept exact decisions for the checklist and current photo submissions';
end;
$$;

rollback;

-- Run after the portal and ScoutCapture review migrations.
begin;

do $$
declare
    org_id uuid := gen_random_uuid();
    property_id uuid := gen_random_uuid();
    reviewer_id uuid := gen_random_uuid();
    old_session uuid := gen_random_uuid();
    latest_session uuid := gen_random_uuid();
    old_snapshot uuid := gen_random_uuid();
    latest_snapshot uuid := gen_random_uuid();
    old_package uuid := gen_random_uuid();
    latest_package uuid := gen_random_uuid();
    old_issue uuid := gen_random_uuid();
    latest_issue uuid := gen_random_uuid();
    old_photo uuid := gen_random_uuid();
    latest_photo uuid := gen_random_uuid();
    submitted_id uuid := gen_random_uuid();
    t timestamptz := now() - interval '1 day';
    report_type text;
    selected_package uuid;
    selected_snapshot uuid;
    selected_session uuid;
    state jsonb;
    saved public.reviewed_report_requests;
begin
    assert not has_function_privilege('authenticated', 'public.current_reviewed_report_state(uuid,uuid)', 'EXECUTE');
    assert has_function_privilege('service_role', 'public.current_reviewed_report_state(uuid,uuid)', 'EXECUTE');
    insert into auth.users (id, aud, role, email) values (reviewer_id, 'authenticated', 'authenticated', reviewer_id || '@example.test');
    insert into public.users_profile (id, email) values (reviewer_id, reviewer_id || '@example.test') on conflict (id) do nothing;
    insert into public.orgs (id, name) values (org_id, 'Current report test');
    insert into public.org_memberships (org_id, user_id, role, access_scope) values (org_id, reviewer_id, 'owner', 'org');
    insert into public.properties (id, org_id, name) values (property_id, org_id, 'Current report test');
    insert into public.sessions (id, org_id, property_id, status, is_sealed, started_at, completed_at)
    values (old_session, org_id, property_id, 'completed', true, t - interval '3 days', t - interval '3 days'),
           (latest_session, org_id, property_id, 'completed', true, t, t);
    insert into public.shots (id, org_id, property_id, session_id, issue_id, capture_kind, issue_status,
                              upload_state, storage_bucket, storage_path)
    values
        (old_photo, org_id, property_id, old_session, old_issue, 'resolved_capture', 'pending_review',
         'uploaded', 'scoutcapture-originals', format('sessions/%s/shots/%s/photo.jpg', old_session, old_photo)),
        (latest_photo, org_id, property_id, latest_session, latest_issue, 'resolved_capture', 'pending_review',
         'uploaded', 'scoutcapture-originals', format('sessions/%s/shots/%s/photo.jpg', latest_session, latest_photo));
    insert into public.observations (id, org_id, property_id, session_id, shot_id, status)
    values (old_issue, org_id, property_id, old_session, old_photo, 'pending_review'),
           (latest_issue, org_id, property_id, latest_session, latest_photo, 'pending_review');

    insert into public.punchlist_activity (id, org_id, property_id, observation_id, shot_id, activity_type,
                                           from_value, to_value, created_at)
    values (submitted_id, org_id, property_id, latest_issue, latest_photo, 'field_resolution_finalized',
            latest_session::text, 'pending_review', t);

    insert into public.session_snapshots (
        id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
        session_status, is_sealed, payload_storage_bucket, payload_storage_path, payload_byte_size,
        raw_session_json_sha256, snapshot_payload_sha256, manifest, created_at
    ) values (
        old_snapshot, org_id, property_id, old_session, 'completed', 1, 'fast_lane_report_handoff',
        'completed', true, 'scoutcapture-session-snapshots',
        public.session_snapshot_expected_storage_path(org_id, property_id, old_session, 'completed', old_snapshot),
        1, repeat('0', 64), repeat('1', 64),
        jsonb_build_object('media', jsonb_build_array(jsonb_build_object('id', old_photo))), t - interval '3 days'
    ), (
        latest_snapshot, org_id, property_id, latest_session, 'completed', 1, 'fast_lane_report_handoff',
        'completed', true, 'scoutcapture-session-snapshots',
        public.session_snapshot_expected_storage_path(org_id, property_id, latest_session, 'completed', latest_snapshot),
        1, repeat('0', 64), repeat('2', 64), jsonb_build_object('fieldResolutionSubmissions', jsonb_build_array(
            jsonb_build_object('activity_id', submitted_id, 'observation_id', latest_issue,
                               'shot_id', latest_photo, 'status', 'pending_review')
        )), t
    );
    insert into public.report_packages (id, org_id, property_id, session_id, snapshot_id, status, generation_trigger,
                                        idempotency_key, session_completed_at, renderer_version)
    values (old_package, org_id, property_id, old_session, old_snapshot, 'ready', 'session_completed',
            'current-test:' || old_snapshot, t - interval '3 days', 'test'),
           (latest_package, org_id, property_id, latest_session, latest_snapshot, 'ready', 'session_completed',
            'current-test:' || latest_snapshot, t, 'test');

    foreach selected_package in array array[old_package, latest_package] loop
        select p.snapshot_id, p.session_id into selected_snapshot, selected_session from public.report_packages p
        where p.id = selected_package;
        foreach report_type in array array['property_report', 'flagged_observations', 'flagged_comparison'] loop
            insert into public.report_package_files (package_id, org_id, property_id, session_id, snapshot_id,
                                                    report_type, storage_path, filename, byte_size, sha256, page_count)
            values (selected_package, org_id, property_id, selected_session, selected_snapshot, report_type,
                    public.report_package_file_expected_storage_path(org_id, property_id, selected_session, selected_package, report_type),
                    report_type || '.pdf', 1, repeat('3', 64), 1);
        end loop;
        if selected_package = old_package then
            assert public.current_reviewed_report_state(org_id, property_id)->>'package_id' is null;
        end if;
    end loop;

    state := public.current_reviewed_report_state(org_id, property_id);
    assert state->>'package_id' = latest_package::text and state->>'unresolved_count' = '2';
    begin
        insert into public.reviewed_report_requests
            (org_id, property_id, source_package_id, requested_by, report_scope, current_state_hash)
        values (org_id, property_id, latest_package, reviewer_id, 'current_property', state->>'state_hash');
        raise exception 'Accepted a current report with unresolved reviews';
    exception when check_violation then null;
    end;

    insert into public.punchlist_activity (org_id, property_id, observation_id, shot_id, activity_type,
                                           from_value, to_value, created_by)
    values (org_id, property_id, old_issue, old_photo, 'completion_approved', 'pending_review', 'resolved', reviewer_id);
    perform public.review_field_resolution_submission(submitted_id, reviewer_id, 'reject');
    update public.observations ob set status = 'resolved' where ob.id = old_issue;

    begin
        insert into public.reviewed_report_requests
            (org_id, property_id, source_package_id, requested_by, report_scope, current_state_hash)
        values (org_id, property_id, latest_package, reviewer_id, 'current_property', state->>'state_hash');
        raise exception 'Accepted a stale property state';
    exception when check_violation then null;
    end;
    state := public.current_reviewed_report_state(org_id, property_id);
    assert state->>'unresolved_count' = '0';
    insert into public.reviewed_report_requests
        (org_id, property_id, source_package_id, requested_by, report_scope, current_state_hash, review_outcomes)
    values (org_id, property_id, latest_package, reviewer_id, 'current_property', state->>'state_hash', '[]')
    returning * into saved;
    assert saved.current_issue_states = state->'issue_states';
    assert jsonb_array_length(saved.review_outcomes) = 2;
    assert saved.review_outcomes @> jsonb_build_array(
        jsonb_build_object('shot_id', old_photo, 'status', 'resolved', 'snapshot_id', old_snapshot),
        jsonb_build_object('shot_id', latest_photo, 'status', 'active', 'snapshot_id', latest_snapshot)
    );
    assert public.current_reviewed_report_state(gen_random_uuid(), property_id)->>'package_id' is null;
    raise notice 'Current reports pin the latest complete package and exact decisions across visits';
end;
$$;

rollback;

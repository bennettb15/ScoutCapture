-- Run after the Website activity migrations and the ScoutCapture reviewed-report migrations.
begin;

do $$
declare
    owner_id uuid := gen_random_uuid();
    field_id uuid := gen_random_uuid();
    portal_admin_id uuid := gen_random_uuid();
    org_id uuid := gen_random_uuid();
    property_id uuid := gen_random_uuid();
    source_session_id uuid := gen_random_uuid();
    source_snapshot_id uuid := gen_random_uuid();
    source_package_id uuid := gen_random_uuid();
    first_issue_id uuid := gen_random_uuid();
    second_issue_id uuid := gen_random_uuid();
    first_shot_id uuid := gen_random_uuid();
    second_shot_id uuid := gen_random_uuid();
    report_type text;
    visit_time timestamptz := now() - interval '1 day';
    stamped boolean;
    outcomes jsonb;
begin
    assert not has_function_privilege('authenticated',
        'public.legacy_reviewed_report_outcomes(uuid,uuid,uuid[])', 'EXECUTE');
    assert has_function_privilege('service_role',
        'public.legacy_reviewed_report_outcomes(uuid,uuid,uuid[])', 'EXECUTE');

    insert into auth.users (id, aud, role, email, created_at, updated_at)
    select actor, 'authenticated', 'authenticated', actor || '@example.test', now(), now()
    from unnest(array[owner_id, field_id, portal_admin_id]) actor;
    insert into public.users_profile (id, email)
    select actor, actor || '@example.test' from unnest(array[owner_id, field_id, portal_admin_id]) actor
    on conflict (id) do nothing;

    insert into public.orgs (id, name, require_review_for_field_resolutions)
    values (org_id, 'Legacy test org', false);
    insert into public.org_memberships (org_id, user_id, role, access_scope)
    values (org_id, owner_id, 'owner', 'org'), (org_id, field_id, 'field', 'org');
    insert into public.properties (id, org_id, name) values (property_id, org_id, 'Legacy test property');
    insert into public.sessions (id, org_id, property_id, status, is_sealed, started_at, completed_at)
    values (source_session_id, org_id, property_id, 'completed', true, visit_time, visit_time);
    insert into public.shots (id, org_id, property_id, session_id, issue_id, capture_kind, issue_status,
                             upload_state, storage_bucket, storage_path)
    values
        (first_shot_id, org_id, property_id, source_session_id, first_issue_id, 'resolved_capture', 'pending_review',
         'uploaded', 'scoutcapture-originals', format('sessions/%s/shots/%s/photo.jpg', source_session_id, first_shot_id)),
        (second_shot_id, org_id, property_id, source_session_id, second_issue_id, 'resolved_capture', 'pending_review',
         'uploaded', 'scoutcapture-originals', format('sessions/%s/shots/%s/photo.jpg', source_session_id, second_shot_id));
    insert into public.observations (id, org_id, property_id, session_id, shot_id, status)
    values (first_issue_id, org_id, property_id, source_session_id, first_shot_id, 'pending_review'),
           (second_issue_id, org_id, property_id, source_session_id, second_shot_id, 'pending_review');

    insert into public.session_snapshots (
        id, org_id, property_id, session_id, snapshot_kind, snapshot_schema_version, trigger,
        session_status, is_sealed, payload_storage_bucket, payload_storage_path, payload_byte_size,
        raw_session_json_sha256, snapshot_payload_sha256, manifest, created_at
    ) values (
        source_snapshot_id, org_id, property_id, source_session_id, 'completed', 1, 'fast_lane_report_handoff',
        'completed', true, 'scoutcapture-session-snapshots',
        public.session_snapshot_expected_storage_path(org_id, property_id, source_session_id, 'completed', source_snapshot_id),
        1, repeat('0', 64), repeat('1', 64),
        jsonb_build_object('media', jsonb_build_array(jsonb_build_object('id', first_shot_id),
                                                    jsonb_build_object('id', second_shot_id))), visit_time
    );
    insert into public.report_packages
        (id, org_id, property_id, session_id, snapshot_id, status, idempotency_key, session_completed_at, renderer_version)
    values (source_package_id, org_id, property_id, source_session_id, source_snapshot_id, 'ready',
            'legacy-review-test:' || source_snapshot_id, visit_time, 'test');

    assert not exists (select 1 from public.legacy_reviewed_report_outcomes(org_id, property_id, array[source_package_id]));
    foreach report_type in array array['property_report', 'flagged_observations', 'flagged_comparison'] loop
        insert into public.report_package_files (package_id, org_id, property_id, session_id, snapshot_id,
                                                report_type, storage_path, filename, byte_size, sha256, page_count)
        values (source_package_id, org_id, property_id, source_session_id, source_snapshot_id, report_type,
                public.report_package_file_expected_storage_path(org_id, property_id, source_session_id, source_package_id, report_type),
                report_type || '.pdf', 1, repeat('2', 64), 1);
    end loop;
    assert (select count(*) = 2 and count(status) = 0 from
        public.legacy_reviewed_report_outcomes(org_id, property_id, array[source_package_id]));

    -- The first event matches the approval already made before rollout.
    insert into public.punchlist_activity (org_id, property_id, observation_id, shot_id, activity_type,
                                           from_value, to_value, created_by)
    values (org_id, property_id, first_issue_id, first_shot_id, 'completion_approved',
            'pending_review', 'resolved', owner_id);
    update public.shots set issue_status = 'resolved' where id = first_shot_id;

    -- An unlinked original-photo event and a field user's exact event cannot substitute for review.
    insert into public.punchlist_activity (org_id, property_id, observation_id, activity_type,
                                           from_value, to_value, created_by)
    values (org_id, property_id, second_issue_id, 'completion_approved', 'pending_review', 'resolved', owner_id);
    insert into public.punchlist_activity (org_id, property_id, observation_id, shot_id, activity_type,
                                           from_value, to_value, created_by, legacy_field_review_verified)
    values (org_id, property_id, second_issue_id, second_shot_id, 'completion_approved',
            'pending_review', 'resolved', field_id, true)
    returning legacy_field_review_verified into stamped;
    assert stamped is false;

    begin
        insert into public.reviewed_report_requests (org_id, property_id, requested_by, source_package_id)
        values (org_id, property_id, owner_id, source_package_id);
        raise exception 'Accepted a legacy source with an unreviewed capture';
    exception when check_violation then null;
    end;

    -- The Website service role can record a verified decision for a global reviewer.
    execute 'set local role service_role';
    insert into public.punchlist_activity (org_id, property_id, observation_id, shot_id, activity_type,
                                           from_value, to_value, created_by)
    values (org_id, property_id, second_issue_id, second_shot_id, 'completion_rejected',
            'pending_review', 'active', portal_admin_id)
    returning legacy_field_review_verified into stamped;
    execute 'reset role';
    assert stamped is true;
    update public.shots set issue_status = 'active' where id = second_shot_id;

    assert (select count(*) = 2 and count(status) = 2 from
        public.legacy_reviewed_report_outcomes(org_id, property_id, array[source_package_id]));
    assert not exists (select 1 from
        public.legacy_reviewed_report_outcomes(org_id, gen_random_uuid(), array[source_package_id]));

    insert into public.reviewed_report_requests (org_id, property_id, requested_by, source_package_id)
    values (org_id, property_id, owner_id, source_package_id) returning review_outcomes into outcomes;
    assert jsonb_array_length(outcomes) = 2;
    assert outcomes @> jsonb_build_array(jsonb_build_object(
        'shot_id', first_shot_id, 'observation_id', first_issue_id, 'status', 'resolved', 'legacy', true
    ));
    assert outcomes @> jsonb_build_array(jsonb_build_object(
        'shot_id', second_shot_id, 'observation_id', second_issue_id, 'status', 'active', 'legacy', true
    ));
    raise notice 'Legacy sources stay eligible after exact decisions and reject incomplete or unverified review';
end;
$$;

rollback;

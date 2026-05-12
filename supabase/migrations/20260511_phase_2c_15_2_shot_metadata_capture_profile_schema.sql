alter table public.properties
    add column if not exists capture_profile text;

alter table public.sessions
    add column if not exists capture_profile text;

alter table public.shots
    add column if not exists property_id uuid,
    add column if not exists building text,
    add column if not exists elevation text,
    add column if not exists detail_type text,
    add column if not exists angle_index integer,
    add column if not exists shot_key text,
    add column if not exists logical_shot_identity text,
    add column if not exists capture_kind text,
    add column if not exists first_capture_kind text,
    add column if not exists is_guided boolean not null default false,
    add column if not exists is_flagged boolean not null default false,
    add column if not exists issue_id uuid,
    add column if not exists issue_status text,
    add column if not exists trade text,
    add column if not exists reason text,
    add column if not exists priority text,
    add column if not exists capture_mode text,
    add column if not exists lens text,
    add column if not exists latitude double precision,
    add column if not exists longitude double precision,
    add column if not exists accuracy_meters double precision,
    add column if not exists image_width integer,
    add column if not exists image_height integer;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'shots_property_id_fkey'
          and conrelid = 'public.shots'::regclass
    ) then
        alter table public.shots
            add constraint shots_property_id_fkey
            foreign key (property_id) references public.properties(id);
    end if;
end;
$$;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'properties_capture_profile_check'
          and conrelid = 'public.properties'::regclass
    ) then
        alter table public.properties
            add constraint properties_capture_profile_check
            check (capture_profile is null or capture_profile in ('residential', 'commercial'));
    end if;
end;
$$;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'sessions_capture_profile_check'
          and conrelid = 'public.sessions'::regclass
    ) then
        alter table public.sessions
            add constraint sessions_capture_profile_check
            check (capture_profile is null or capture_profile in ('residential', 'commercial'));
    end if;
end;
$$;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'shots_capture_kind_check'
          and conrelid = 'public.shots'::regclass
    ) then
        alter table public.shots
            add constraint shots_capture_kind_check
            check (
                capture_kind is null
                or capture_kind in (
                    'captured',
                    'retake',
                    'follow_up_capture',
                    'reference',
                    'resolved_capture',
                    'reclassified'
                )
            );
    end if;
end;
$$;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'shots_first_capture_kind_check'
          and conrelid = 'public.shots'::regclass
    ) then
        alter table public.shots
            add constraint shots_first_capture_kind_check
            check (first_capture_kind is null or first_capture_kind in ('captured'));
    end if;
end;
$$;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'shots_priority_check'
          and conrelid = 'public.shots'::regclass
    ) then
        alter table public.shots
            add constraint shots_priority_check
            check (priority is null or priority in ('Low', 'Medium', 'High', 'Critical'));
    end if;
end;
$$;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'shots_angle_index_check'
          and conrelid = 'public.shots'::regclass
    ) then
        alter table public.shots
            add constraint shots_angle_index_check
            check (angle_index is null or angle_index >= 0);
    end if;
end;
$$;

create index if not exists idx_shots_property_active
    on public.shots (property_id)
    where deleted_at is null;

create index if not exists idx_shots_session_shot_key_active
    on public.shots (session_id, shot_key)
    where deleted_at is null and shot_key is not null;

create index if not exists idx_shots_session_logical_identity_active
    on public.shots (session_id, logical_shot_identity)
    where deleted_at is null and logical_shot_identity is not null;

create index if not exists idx_shots_session_guided_active
    on public.shots (session_id, is_guided)
    where deleted_at is null;

create index if not exists idx_shots_session_flagged_active
    on public.shots (session_id, is_flagged)
    where deleted_at is null;

create index if not exists idx_shots_issue_active
    on public.shots (issue_id)
    where deleted_at is null and issue_id is not null;

create index if not exists idx_sessions_property_capture_profile_active
    on public.sessions (property_id, capture_profile)
    where deleted_at is null and capture_profile is not null;

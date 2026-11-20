-- Use the most recent server write when deciding whether an occupied lease has
-- expired. A missing heartbeat on a newly created claim is not an expired lock.
create or replace function public.property_status_occupied_lease_expired(
    target_status text,
    target_heartbeat_at timestamptz,
    target_updated_at timestamptz
)
returns boolean
language sql
stable
as $$
    select target_status = 'occupied'
       and greatest(target_heartbeat_at, target_updated_at)
           < timezone('utc', now()) - interval '3 minutes';
$$;

-- A stale occupied claim is an expired lease. Any authorized property writer may
-- recover it after the material-work checks below. Drafts remain owner-only.
-- This also serves the existing manual recovery action.
create or replace function public.release_stale_property_lock(target_property_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    current_status public.property_status%rowtype;
    current_occupancy public.property_session_occupancy%rowtype;
    stale_before timestamptz := timezone('utc', now()) - interval '3 minutes';
begin
    -- All operational status transitions serialize on this row.
    select * into current_status
    from public.property_status
    where property_id = target_property_id and org_id = target_org_id
    for update;

    if current_status.property_id is null or current_status.status in ('idle', 'exported') then
        return 'already_unlocked';
    end if;
    if current_status.status not in ('occupied', 'draft') then
        return 'protected_work';
    end if;
    if current_status.status = 'draft'
       and current_status.owner_user_id is distinct from actor_id then
        return 'different_owner';
    end if;
    if not public.property_status_occupied_lease_expired(
        current_status.status, current_status.heartbeat_at, current_status.updated_at
    ) and current_status.status = 'occupied' then
        return 'recent_activity';
    end if;
    if current_status.status = 'draft'
       and greatest(current_status.heartbeat_at, current_status.updated_at) >= stale_before then
        return 'recent_activity';
    end if;

    select * into current_occupancy
    from public.property_session_occupancy
    where property_id = target_property_id and org_id = target_org_id
    for update;
    if current_occupancy.property_id is not null then
        if (current_status.status = 'draft'
            and current_occupancy.occupied_by_user_id is distinct from actor_id)
           or greatest(current_occupancy.occupied_at, current_occupancy.updated_at) >= stale_before then
            return 'recent_or_other_occupancy';
        end if;
    end if;

    -- Lock existing sessions before inspecting their work and clearing markers.
    perform 1 from public.sessions
    where property_id = target_property_id and org_id = target_org_id and deleted_at is null
    for update;

    if exists (
        select 1 from public.session_upload_intents intent
        where intent.property_id = target_property_id and intent.org_id = target_org_id
          and intent.completed_snapshot_id is null
    ) or exists (
        select 1 from public.sessions session_row
        where session_row.property_id = target_property_id
          and session_row.org_id = target_org_id and session_row.deleted_at is null
          and coalesce(session_row.is_sealed, false) = true
          and session_row.first_delivered_at is null
          and session_row.exported_at is null
    ) or exists (
        select 1 from public.sessions session_row
        join public.shots shot on shot.session_id = session_row.id
        where session_row.property_id = target_property_id
          and session_row.org_id = target_org_id and session_row.deleted_at is null
          and session_row.first_delivered_at is null
          and session_row.exported_at is null
          and shot.org_id = target_org_id and shot.deleted_at is null
          and coalesce(shot.lifecycle_state, 'active') not in ('retired', 'deleted')
    ) then
        return 'protected_work';
    end if;

    if exists (
        select 1 from public.sessions session_row
        where session_row.property_id = target_property_id
          and session_row.org_id = target_org_id and session_row.deleted_at is null
          and (session_row.locked_by_user_id is not null
               or nullif(btrim(coalesce(session_row.locked_by_device_id, '')), '') is not null
               or session_row.locked_at is not null)
          and ((current_status.status = 'draft'
                and session_row.locked_by_user_id is distinct from actor_id)
               or session_row.locked_at >= stale_before
               or session_row.updated_at >= stale_before)
    ) then
        return 'recent_or_other_session';
    end if;

    delete from public.property_session_occupancy
    where property_id = target_property_id and org_id = target_org_id;

    update public.sessions
    set locked_by_user_id = null,
        locked_by_device_id = null,
        locked_at = null,
        updated_by = actor_id,
        revision = revision + 1
    where property_id = target_property_id and org_id = target_org_id
      and deleted_at is null
      and (locked_by_user_id is not null
           or nullif(btrim(coalesce(locked_by_device_id, '')), '') is not null
           or locked_at is not null);

    update public.property_status
    set status = 'idle',
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = null,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = actor_id,
        status_reason = 'manual_stale_lock_release',
        revision = revision + 1
    where property_id = target_property_id and org_id = target_org_id;

    return 'released';
end;
$$;

revoke all on function public.release_stale_property_lock(uuid) from public, anon;
grant execute on function public.release_stale_property_lock(uuid) to authenticated;

-- Lightweight property-entry gate.
--
-- This RPC answers the one hot-path question the app needs before entering a
-- property: can the current actor proceed, or is the property locked/pending?
-- It intentionally uses only property_status and does not rebuild/scan sessions,
-- shots, snapshots, reports, archives, or history.

create or replace function public.get_or_claim_property_entry_status(
    target_property_id uuid,
    target_device_id text,
    target_session_id uuid default null
)
returns table (
    entry_state text,
    property_id uuid,
    lock_session_id uuid,
    locked_by_user_id uuid,
    locked_by_email text,
    locked_by_device_id text,
    locked_at timestamptz,
    updated_at timestamptz,
    server_timestamp timestamptz,
    lock_age_seconds integer,
    requires_fallback boolean,
    reason text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    normalized_device_id text := nullif(btrim(coalesce(target_device_id, '')), '');
    now_utc timestamptz := timezone('utc', now());
    existing public.property_status%rowtype;
    owns_existing boolean := false;
    is_existing_stale boolean := false;
    owner_email text;
    actor_email text;
    previous_status text;
begin
    select *
    into existing
    from public.property_status
    where property_status.property_id = target_property_id
    for update;

    if existing.property_id is null then
        entry_state := 'unknown_requires_fallback';
        property_id := target_property_id;
        lock_session_id := null;
        locked_by_user_id := null;
        locked_by_email := null;
        locked_by_device_id := null;
        locked_at := null;
        updated_at := null;
        server_timestamp := now_utc;
        lock_age_seconds := null;
        requires_fallback := true;
        reason := 'missing_property_status_row';
        return next;
        return;
    end if;

    if existing.org_id <> target_org_id then
        entry_state := 'unknown_requires_fallback';
        property_id := target_property_id;
        lock_session_id := null;
        locked_by_user_id := null;
        locked_by_email := null;
        locked_by_device_id := null;
        locked_at := null;
        updated_at := existing.updated_at;
        server_timestamp := now_utc;
        lock_age_seconds := null;
        requires_fallback := true;
        reason := 'property_status_org_mismatch';
        return next;
        return;
    end if;

    owns_existing := public.property_status_actor_owns(
        existing.owner_user_id,
        existing.owner_device_id,
        normalized_device_id
    );
    is_existing_stale := public.property_status_occupied_lease_expired(
        existing.status,
        existing.heartbeat_at,
        existing.updated_at
    );

    select profile.email
    into owner_email
    from public.users_profile profile
    where profile.id = existing.owner_user_id
      and profile.deleted_at is null;

    select profile.email
    into actor_email
    from public.users_profile profile
    where profile.id = actor_id
      and profile.deleted_at is null;

    if existing.status = 'pending_export' then
        entry_state := 'pending_export';
        property_id := target_property_id;
        lock_session_id := existing.pending_export_session_id;
        locked_by_user_id := existing.owner_user_id;
        locked_by_email := owner_email;
        locked_by_device_id := existing.owner_device_id;
        locked_at := coalesce(existing.heartbeat_at, existing.updated_at);
        updated_at := existing.updated_at;
        server_timestamp := now_utc;
        lock_age_seconds := extract(epoch from now_utc - coalesce(existing.heartbeat_at, existing.updated_at))::integer;
        requires_fallback := false;
        reason := 'pending_export_blocks_entry';
        return next;
        return;
    end if;

    if existing.status = 'draft' then
        entry_state := case
            when owns_existing then 'locked_by_current_user'
            else 'locked_by_other_user'
        end;
        property_id := target_property_id;
        lock_session_id := existing.draft_session_id;
        locked_by_user_id := existing.owner_user_id;
        locked_by_email := owner_email;
        locked_by_device_id := existing.owner_device_id;
        locked_at := coalesce(existing.heartbeat_at, existing.updated_at);
        updated_at := existing.updated_at;
        server_timestamp := now_utc;
        lock_age_seconds := extract(epoch from now_utc - coalesce(existing.heartbeat_at, existing.updated_at))::integer;
        requires_fallback := false;
        reason := case
            when owns_existing then 'current_user_draft'
            else 'other_user_draft'
        end;
        return next;
        return;
    end if;

    if existing.status = 'occupied' then
        if owns_existing then
            update public.property_status
            set heartbeat_at = now_utc,
                updated_by = actor_id,
                status_reason = 'entry_gate_current_user_heartbeat',
                revision = revision + 1
            where property_status.property_id = target_property_id
            returning * into existing;

            entry_state := 'locked_by_current_user';
            property_id := target_property_id;
            lock_session_id := existing.active_session_id;
            locked_by_user_id := existing.owner_user_id;
            locked_by_email := owner_email;
            locked_by_device_id := existing.owner_device_id;
            locked_at := existing.heartbeat_at;
            updated_at := existing.updated_at;
            server_timestamp := now_utc;
            lock_age_seconds := 0;
            requires_fallback := false;
            reason := 'current_user_occupied';
            return next;
            return;
        end if;

        if not is_existing_stale then
            entry_state := 'locked_by_other_user';
            property_id := target_property_id;
            lock_session_id := existing.active_session_id;
            locked_by_user_id := existing.owner_user_id;
            locked_by_email := owner_email;
            locked_by_device_id := existing.owner_device_id;
            locked_at := coalesce(existing.heartbeat_at, existing.updated_at);
            updated_at := existing.updated_at;
            server_timestamp := now_utc;
            lock_age_seconds := extract(epoch from now_utc - coalesce(existing.heartbeat_at, existing.updated_at))::integer;
            requires_fallback := false;
            reason := 'other_user_occupied';
            return next;
            return;
        end if;

        -- Reclaim only an expired, zero-material lease. The recovery RPC locks
        -- and checks occupancy, sessions, shots, and unfinished uploads before
        -- releasing. Re-enter the gate in this same transaction to claim it.
        if target_session_id is not null then
            if public.release_stale_property_lock(target_property_id) = 'released' then
                return query select * from public.get_or_claim_property_entry_status(
                    target_property_id, normalized_device_id, target_session_id
                );
                return;
            end if;
        end if;

        entry_state := 'stale_claimable';
        property_id := target_property_id;
        lock_session_id := existing.active_session_id;
        locked_by_user_id := existing.owner_user_id;
        locked_by_email := owner_email;
        locked_by_device_id := existing.owner_device_id;
        locked_at := coalesce(existing.heartbeat_at, existing.updated_at);
        updated_at := existing.updated_at;
        server_timestamp := now_utc;
        lock_age_seconds := extract(epoch from now_utc - coalesce(existing.heartbeat_at, existing.updated_at))::integer;
        requires_fallback := false;
        reason := 'occupied_stale_claimable';
        return next;
        return;
    end if;

    if existing.status in ('idle', 'exported') then
        previous_status := existing.status;

        if target_session_id is null then
            entry_state := 'unknown_requires_fallback';
            property_id := target_property_id;
            lock_session_id := null;
            locked_by_user_id := null;
            locked_by_email := null;
            locked_by_device_id := null;
            locked_at := null;
            updated_at := existing.updated_at;
            server_timestamp := now_utc;
            lock_age_seconds := null;
            requires_fallback := true;
            reason := 'claim_requires_session_id';
            return next;
            return;
        end if;

        update public.property_status
        set status = 'occupied',
            active_session_id = target_session_id,
            draft_session_id = null,
            pending_export_session_id = null,
            owner_user_id = actor_id,
            owner_device_id = normalized_device_id,
            heartbeat_at = now_utc,
            updated_by = actor_id,
            status_reason = 'entry_gate_claim',
            revision = revision + 1
        where property_status.property_id = target_property_id
        returning * into existing;

        entry_state := 'unlocked_and_claimed';
        property_id := target_property_id;
        lock_session_id := existing.active_session_id;
        locked_by_user_id := existing.owner_user_id;
        locked_by_email := actor_email;
        locked_by_device_id := existing.owner_device_id;
        locked_at := existing.heartbeat_at;
        updated_at := existing.updated_at;
        server_timestamp := now_utc;
        lock_age_seconds := 0;
        requires_fallback := false;
        reason := 'claimed_from_' || previous_status;
        return next;
        return;
    end if;

    entry_state := 'unknown_requires_fallback';
    property_id := target_property_id;
    lock_session_id := null;
    locked_by_user_id := existing.owner_user_id;
    locked_by_email := owner_email;
    locked_by_device_id := existing.owner_device_id;
    locked_at := coalesce(existing.heartbeat_at, existing.updated_at);
    updated_at := existing.updated_at;
    server_timestamp := now_utc;
    lock_age_seconds := extract(epoch from now_utc - coalesce(existing.heartbeat_at, existing.updated_at))::integer;
    requires_fallback := true;
    reason := 'unsupported_property_status_' || coalesce(existing.status, 'nil');
    return next;
end;
$$;


comment on function public.get_or_claim_property_entry_status(uuid, text, uuid) is
    'Atomic property-entry gate: expired empty occupied leases are reclaimed after server-side material checks; drafts and uploads stay protected.';

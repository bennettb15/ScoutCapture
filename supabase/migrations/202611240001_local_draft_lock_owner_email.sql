-- Show the account email for a device-scoped local draft without changing
-- its device-only ownership or stale-claim semantics.

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
    where profile.id = case
        -- A local-only draft is scoped to a device. Its owner_user_id stays null
        -- deliberately, while updated_by records the account that saved it.
        when existing.status = 'draft' and existing.local_draft_session_id is not null
            then coalesce(existing.owner_user_id, existing.updated_by)
        else existing.owner_user_id
      end
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
            local_draft_session_id = null,
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



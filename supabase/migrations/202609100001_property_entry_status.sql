-- Lightweight one-property session entry status.
-- This is intentionally read-only and does not rebuild property/session state.

create or replace function public.get_property_entry_status(
    target_property_id uuid,
    target_device_id text
)
returns table (
    entry_state text,
    property_id uuid,
    org_id uuid,
    property_status text,
    active_session_id uuid,
    draft_session_id uuid,
    pending_export_session_id uuid,
    last_exported_session_id uuid,
    lock_session_id uuid,
    lock_owner_user_id uuid,
    lock_owner_email text,
    lock_owner_device_id text,
    lock_heartbeat_at timestamptz,
    status_updated_at timestamptz,
    status_updated_by uuid,
    status_reason text,
    status_revision bigint,
    server_timestamp timestamptz,
    lock_age_seconds integer,
    is_stale boolean
)
language sql
stable
security definer
set search_path = public
as $$
    with target_property as (
        select property.id, property.org_id
        from public.properties property
        where property.id = target_property_id
          and property.deleted_at is null
          and auth.uid() is not null
          and public.has_property_access(property.org_id, property.id)
          and public.property_belongs_to_org(property.id, property.org_id)
        limit 1
    ),
    status_row as (
        select status.*
        from public.property_status status
        join target_property property
          on property.id = status.property_id
         and property.org_id = status.org_id
        limit 1
    ),
    entry as (
        select
            property.id as property_id,
            property.org_id,
            status.status,
            status.active_session_id,
            status.draft_session_id,
            status.pending_export_session_id,
            status.last_exported_session_id,
            status.owner_user_id,
            status.owner_device_id,
            status.heartbeat_at,
            status.updated_at,
            status.updated_by,
            status.status_reason,
            status.revision,
            public.property_status_actor_owns(
                status.owner_user_id,
                status.owner_device_id,
                target_device_id
            ) as owned_by_current_actor,
            public.property_status_is_stale(status.status, status.heartbeat_at) as stale,
            timezone('utc', now()) as server_timestamp
        from target_property property
        left join status_row status on true
    )
    select
        case
            when entry.status is null then 'unknown_requires_verification'
            when entry.status in ('idle', 'exported') then 'unlocked'
            when entry.status = 'pending_export' then 'pending_export'
            when entry.status in ('occupied', 'draft') and entry.owned_by_current_actor then 'locked_current_user'
            when entry.status = 'occupied' and entry.stale then 'stale_claimable'
            when entry.status in ('occupied', 'draft') then 'locked_other_user'
            else 'unknown_requires_verification'
        end as entry_state,
        entry.property_id,
        entry.org_id,
        entry.status as property_status,
        entry.active_session_id,
        entry.draft_session_id,
        entry.pending_export_session_id,
        entry.last_exported_session_id,
        coalesce(entry.draft_session_id, entry.active_session_id, entry.pending_export_session_id) as lock_session_id,
        coalesce(
            entry.owner_user_id,
            case when entry.status = 'pending_export' then entry.updated_by else null end
        ) as lock_owner_user_id,
        owner.email as lock_owner_email,
        entry.owner_device_id as lock_owner_device_id,
        entry.heartbeat_at as lock_heartbeat_at,
        entry.updated_at as status_updated_at,
        entry.updated_by as status_updated_by,
        entry.status_reason,
        entry.revision as status_revision,
        entry.server_timestamp,
        case
            when coalesce(entry.heartbeat_at, entry.updated_at) is null then null
            else greatest(
                0,
                floor(extract(epoch from entry.server_timestamp - coalesce(entry.heartbeat_at, entry.updated_at)))::integer
            )
        end as lock_age_seconds,
        coalesce(entry.stale, false) as is_stale
    from entry
    left join public.users_profile owner
      on owner.id = coalesce(
          entry.owner_user_id,
          case when entry.status = 'pending_export' then entry.updated_by else null end
      );
$$;

revoke all on function public.get_property_entry_status(uuid, text) from public;
grant execute on function public.get_property_entry_status(uuid, text) to authenticated;

-- Phase 2C-27F-Z4 Slice 1
-- property_status is the current operational state for a property list row.
-- It controls only hub badges, draft/pending counts, occupied/locked display,
-- pre-entry blocking, and delete eligibility.
--
-- Sessions, shots, observations, session_events, export artifacts, guided/flagged
-- metadata, report generation, and activity/history remain their own source of
-- truth. property_status is intentionally rebuildable from those detail/history
-- sources and must not be used as a replacement for them.

create table if not exists public.property_status (
    property_id uuid primary key references public.properties(id) on delete cascade,
    org_id uuid not null references public.orgs(id),
    status text not null default 'idle',
    active_session_id uuid,
    draft_session_id uuid,
    pending_export_session_id uuid,
    last_exported_session_id uuid,
    owner_user_id uuid references public.users_profile(id),
    owner_device_id text,
    heartbeat_at timestamptz,
    updated_at timestamptz not null default timezone('utc', now()),
    updated_by uuid references public.users_profile(id),
    status_reason text not null default 'initial',
    revision bigint not null default 1,
    constraint property_status_status_check
        check (status in ('idle', 'occupied', 'draft', 'pending_export', 'exported')),
    constraint property_status_occupied_owner_check
        check (
            status <> 'occupied'
            or owner_user_id is not null
            or nullif(btrim(coalesce(owner_device_id, '')), '') is not null
        ),
    constraint property_status_draft_owner_check
        check (
            status <> 'draft'
            or (
                draft_session_id is not null
                and (
                    owner_user_id is not null
                    or nullif(btrim(coalesce(owner_device_id, '')), '') is not null
                )
            )
        ),
    constraint property_status_pending_export_session_check
        check (status <> 'pending_export' or pending_export_session_id is not null),
    constraint property_status_exported_session_check
        check (status <> 'exported' or last_exported_session_id is not null)
);

comment on table public.property_status is
    'Current operational property state for list badges/counts/pre-entry/delete only; sessions/shots/events remain detail and history sources of truth.';
comment on column public.property_status.status is
    'Operational state: idle, occupied, draft, pending_export, exported. Do not use for report or historical session truth.';
comment on column public.property_status.active_session_id is
    'Transient entry/occupancy session id when known; may point to a pre-material local-first shell not yet persisted in sessions.';
comment on column public.property_status.draft_session_id is
    'Current unresolved material draft session id for operational locking/badges only.';
comment on column public.property_status.pending_export_session_id is
    'Current sealed-undelivered session id for operational Pending Export display only.';
comment on column public.property_status.last_exported_session_id is
    'Latest delivered/exported session id for operational release/exported state only.';
comment on column public.property_status.heartbeat_at is
    'Freshness marker for transient occupancy and active owner heartbeat; material draft ownership is not auto-released solely by heartbeat timeout.';
comment on column public.property_status.status_reason is
    'Diagnostic transition reason for the latest operational status write.';

create trigger set_property_status_updated_at
    before update on public.property_status
    for each row
    execute function public.set_updated_at();

create index if not exists idx_property_status_org_property
    on public.property_status (org_id, property_id);

create index if not exists idx_property_status_org_status_updated
    on public.property_status (org_id, status, updated_at desc);

create index if not exists idx_property_status_org_owner
    on public.property_status (org_id, owner_user_id, owner_device_id)
    where owner_user_id is not null
       or nullif(btrim(coalesce(owner_device_id, '')), '') is not null;

create index if not exists idx_property_status_draft_session
    on public.property_status (draft_session_id)
    where draft_session_id is not null;

create index if not exists idx_property_status_pending_export_session
    on public.property_status (pending_export_session_id)
    where pending_export_session_id is not null;

create index if not exists idx_property_status_occupied_heartbeat
    on public.property_status (org_id, heartbeat_at)
    where status = 'occupied';

alter table public.property_status enable row level security;

revoke all on public.property_status from public, anon, authenticated;
grant select on public.property_status to authenticated;
grant select, insert, update, delete on public.property_status to service_role;

drop policy if exists property_status_select_property_access on public.property_status;
create policy property_status_select_property_access
on public.property_status
for select
to authenticated
using (
    public.has_property_access(org_id, property_id)
    and public.property_belongs_to_org(property_id, org_id)
);

create or replace function public.property_status_actor_can_write(
    target_org_id uuid,
    target_property_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select auth.uid() is not null
       and public.has_org_role(target_org_id, array['owner', 'manager', 'field'])
       and public.property_belongs_to_org(target_property_id, target_org_id)
       and public.has_property_access(target_org_id, target_property_id);
$$;

create or replace function public.property_status_actor_owns(
    target_owner_user_id uuid,
    target_owner_device_id text,
    target_device_id text
)
returns boolean
language sql
stable
as $$
    select case
        when nullif(btrim(coalesce(target_owner_device_id, '')), '') is not null then
            nullif(btrim(coalesce(target_device_id, '')), '') is not null
            and btrim(target_owner_device_id) = btrim(target_device_id)
        else
            target_owner_user_id is not null
            and target_owner_user_id = auth.uid()
    end;
$$;

create or replace function public.property_status_is_stale(
    target_status text,
    target_heartbeat_at timestamptz
)
returns boolean
language sql
stable
as $$
    select target_status = 'occupied'
       and (
           target_heartbeat_at is null
           or target_heartbeat_at < timezone('utc', now()) - interval '30 minutes'
       );
$$;

create or replace function public.property_status_session_matches_property(
    target_org_id uuid,
    target_property_id uuid,
    target_session_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select target_session_id is not null
       and exists (
           select 1
           from public.sessions session_row
           where session_row.id = target_session_id
             and session_row.org_id = target_org_id
             and session_row.property_id = target_property_id
             and session_row.deleted_at is null
       );
$$;

create or replace function public.property_status_property_org(target_property_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    target_org_id uuid;
begin
    select property.org_id
    into target_org_id
    from public.properties property
    where property.id = target_property_id
      and property.deleted_at is null;

    if target_org_id is null then
        raise exception 'Property not found or unavailable.'
            using errcode = 'P0002';
    end if;

    return target_org_id;
end;
$$;

create or replace function public.property_status_assert_writer(
    target_property_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_property_org(target_property_id);
begin
    if auth.uid() is null then
        raise exception 'Authenticated user required.'
            using errcode = '28000';
    end if;

    if not public.property_status_actor_can_write(target_org_id, target_property_id) then
        raise exception 'Property status write is not allowed for this actor.'
            using errcode = '42501';
    end if;

    return target_org_id;
end;
$$;

create or replace function public.property_status_assert_not_blocked(
    existing_status public.property_status,
    target_device_id text,
    allow_stale_occupied_override boolean default true
)
returns void
language plpgsql
stable
as $$
begin
    if existing_status.property_id is null then
        return;
    end if;

    if existing_status.status = 'draft'
       and not public.property_status_actor_owns(
           existing_status.owner_user_id,
           existing_status.owner_device_id,
           target_device_id
       ) then
        raise exception 'Property has an unresolved draft owned by another actor.'
            using errcode = 'P0001';
    end if;

    if existing_status.status = 'occupied'
       and not public.property_status_actor_owns(
           existing_status.owner_user_id,
           existing_status.owner_device_id,
           target_device_id
       )
       and (
           not allow_stale_occupied_override
           or not public.property_status_is_stale(existing_status.status, existing_status.heartbeat_at)
       ) then
        raise exception 'Property is occupied by another actor.'
            using errcode = 'P0001';
    end if;

    if existing_status.status = 'pending_export' then
        raise exception 'Property has a pending export session.'
            using errcode = 'P0001';
    end if;
end;
$$;

create or replace function public.claim_property_status(
    target_property_id uuid,
    target_session_id uuid,
    target_device_id text,
    target_status_reason text default 'claim_property'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    existing public.property_status%rowtype;
    result public.property_status%rowtype;
begin
    select *
    into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    perform public.property_status_assert_not_blocked(existing, target_device_id, true);

    insert into public.property_status (
        property_id,
        org_id,
        status,
        active_session_id,
        draft_session_id,
        pending_export_session_id,
        last_exported_session_id,
        owner_user_id,
        owner_device_id,
        heartbeat_at,
        updated_by,
        status_reason,
        revision
    )
    values (
        target_property_id,
        target_org_id,
        'occupied',
        target_session_id,
        null,
        null,
        null,
        actor_id,
        nullif(btrim(coalesce(target_device_id, '')), ''),
        timezone('utc', now()),
        actor_id,
        coalesce(nullif(btrim(target_status_reason), ''), 'claim_property'),
        1
    )
    on conflict (property_id) do update
    set org_id = excluded.org_id,
        status = excluded.status,
        active_session_id = excluded.active_session_id,
        draft_session_id = null,
        pending_export_session_id = null,
        last_exported_session_id = property_status.last_exported_session_id,
        owner_user_id = excluded.owner_user_id,
        owner_device_id = excluded.owner_device_id,
        heartbeat_at = excluded.heartbeat_at,
        updated_by = excluded.updated_by,
        status_reason = excluded.status_reason,
        revision = public.property_status.revision + 1
    returning * into result;

    return result;
end;
$$;

create or replace function public.heartbeat_property_status(
    target_property_id uuid,
    target_device_id text,
    target_status_reason text default 'heartbeat'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    existing public.property_status%rowtype;
    result public.property_status%rowtype;
begin
    select *
    into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    if existing.property_id is null then
        raise exception 'Property status row not found.'
            using errcode = 'P0002';
    end if;

    if existing.org_id <> target_org_id then
        raise exception 'Property status org mismatch.'
            using errcode = 'P0001';
    end if;

    if existing.status not in ('occupied', 'draft') then
        raise exception 'Property status heartbeat is only valid for occupied or draft states.'
            using errcode = 'P0001';
    end if;

    if not public.property_status_actor_owns(existing.owner_user_id, existing.owner_device_id, target_device_id) then
        raise exception 'Only the property status owner can heartbeat this row.'
            using errcode = '42501';
    end if;

    update public.property_status
    set heartbeat_at = timezone('utc', now()),
        updated_by = actor_id,
        status_reason = coalesce(nullif(btrim(target_status_reason), ''), 'heartbeat'),
        revision = revision + 1
    where property_id = target_property_id
    returning * into result;

    return result;
end;
$$;

create or replace function public.promote_property_status_draft(
    target_property_id uuid,
    target_session_id uuid,
    target_device_id text,
    target_status_reason text default 'promote_draft'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    existing public.property_status%rowtype;
    result public.property_status%rowtype;
begin
    if not public.property_status_session_matches_property(target_org_id, target_property_id, target_session_id) then
        raise exception 'Draft session does not belong to this property.'
            using errcode = 'P0001';
    end if;

    select *
    into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    perform public.property_status_assert_not_blocked(existing, target_device_id, true);

    insert into public.property_status (
        property_id,
        org_id,
        status,
        active_session_id,
        draft_session_id,
        pending_export_session_id,
        last_exported_session_id,
        owner_user_id,
        owner_device_id,
        heartbeat_at,
        updated_by,
        status_reason,
        revision
    )
    values (
        target_property_id,
        target_org_id,
        'draft',
        target_session_id,
        target_session_id,
        null,
        null,
        actor_id,
        nullif(btrim(coalesce(target_device_id, '')), ''),
        timezone('utc', now()),
        actor_id,
        coalesce(nullif(btrim(target_status_reason), ''), 'promote_draft'),
        1
    )
    on conflict (property_id) do update
    set org_id = excluded.org_id,
        status = excluded.status,
        active_session_id = excluded.active_session_id,
        draft_session_id = excluded.draft_session_id,
        pending_export_session_id = null,
        last_exported_session_id = property_status.last_exported_session_id,
        owner_user_id = excluded.owner_user_id,
        owner_device_id = excluded.owner_device_id,
        heartbeat_at = excluded.heartbeat_at,
        updated_by = excluded.updated_by,
        status_reason = excluded.status_reason,
        revision = public.property_status.revision + 1
    returning * into result;

    return result;
end;
$$;

create or replace function public.set_property_status_pending_export(
    target_property_id uuid,
    target_session_id uuid,
    target_device_id text,
    target_status_reason text default 'pending_export'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    existing public.property_status%rowtype;
    result public.property_status%rowtype;
begin
    if not public.property_status_session_matches_property(target_org_id, target_property_id, target_session_id) then
        raise exception 'Pending export session does not belong to this property.'
            using errcode = 'P0001';
    end if;

    select *
    into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    if existing.property_id is not null
       and existing.status = 'draft'
       and not public.property_status_actor_owns(existing.owner_user_id, existing.owner_device_id, target_device_id) then
        raise exception 'Cannot finalize another actor''s unresolved draft.'
            using errcode = 'P0001';
    end if;

    if existing.property_id is not null
       and existing.status = 'occupied'
       and not public.property_status_actor_owns(existing.owner_user_id, existing.owner_device_id, target_device_id)
       and not public.property_status_is_stale(existing.status, existing.heartbeat_at) then
        raise exception 'Cannot finalize while another actor occupies the property.'
            using errcode = 'P0001';
    end if;

    insert into public.property_status (
        property_id,
        org_id,
        status,
        active_session_id,
        draft_session_id,
        pending_export_session_id,
        last_exported_session_id,
        owner_user_id,
        owner_device_id,
        heartbeat_at,
        updated_by,
        status_reason,
        revision
    )
    values (
        target_property_id,
        target_org_id,
        'pending_export',
        null,
        null,
        target_session_id,
        null,
        null,
        null,
        null,
        actor_id,
        coalesce(nullif(btrim(target_status_reason), ''), 'pending_export'),
        1
    )
    on conflict (property_id) do update
    set org_id = excluded.org_id,
        status = excluded.status,
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = excluded.pending_export_session_id,
        last_exported_session_id = property_status.last_exported_session_id,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = excluded.updated_by,
        status_reason = excluded.status_reason,
        revision = public.property_status.revision + 1
    returning * into result;

    return result;
end;
$$;

create or replace function public.set_property_status_exported(
    target_property_id uuid,
    target_session_id uuid,
    target_device_id text default null,
    target_status_reason text default 'exported'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    existing public.property_status%rowtype;
    result public.property_status%rowtype;
begin
    if not public.property_status_session_matches_property(target_org_id, target_property_id, target_session_id) then
        raise exception 'Exported session does not belong to this property.'
            using errcode = 'P0001';
    end if;

    select *
    into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    if existing.property_id is not null
       and existing.status = 'draft'
       and not public.property_status_actor_owns(existing.owner_user_id, existing.owner_device_id, target_device_id) then
        raise exception 'Cannot export over another actor''s unresolved draft.'
            using errcode = 'P0001';
    end if;

    if existing.property_id is not null
       and existing.status = 'occupied'
       and not public.property_status_actor_owns(existing.owner_user_id, existing.owner_device_id, target_device_id)
       and not public.property_status_is_stale(existing.status, existing.heartbeat_at) then
        raise exception 'Cannot export while another actor occupies the property.'
            using errcode = 'P0001';
    end if;

    insert into public.property_status (
        property_id,
        org_id,
        status,
        active_session_id,
        draft_session_id,
        pending_export_session_id,
        last_exported_session_id,
        owner_user_id,
        owner_device_id,
        heartbeat_at,
        updated_by,
        status_reason,
        revision
    )
    values (
        target_property_id,
        target_org_id,
        'exported',
        null,
        null,
        null,
        target_session_id,
        null,
        null,
        null,
        actor_id,
        coalesce(nullif(btrim(target_status_reason), ''), 'exported'),
        1
    )
    on conflict (property_id) do update
    set org_id = excluded.org_id,
        status = excluded.status,
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = null,
        last_exported_session_id = excluded.last_exported_session_id,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = excluded.updated_by,
        status_reason = excluded.status_reason,
        revision = public.property_status.revision + 1
    returning * into result;

    return result;
end;
$$;

create or replace function public.release_property_status_if_owner(
    target_property_id uuid,
    target_device_id text,
    target_status_reason text default 'release_if_owner'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    existing public.property_status%rowtype;
    result public.property_status%rowtype;
begin
    select *
    into existing
    from public.property_status
    where property_id = target_property_id
    for update;

    if existing.property_id is null then
        insert into public.property_status (
            property_id,
            org_id,
            status,
            updated_by,
            status_reason
        )
        values (
            target_property_id,
            target_org_id,
            'idle',
            actor_id,
            coalesce(nullif(btrim(target_status_reason), ''), 'release_if_owner_missing_row')
        )
        returning * into result;

        return result;
    end if;

    if existing.status in ('occupied', 'draft')
       and not public.property_status_actor_owns(existing.owner_user_id, existing.owner_device_id, target_device_id) then
        raise exception 'Only the property status owner can release this row.'
            using errcode = '42501';
    end if;

    if existing.status not in ('occupied', 'draft') then
        return existing;
    end if;

    update public.property_status
    set status = 'idle',
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = null,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = actor_id,
        status_reason = coalesce(nullif(btrim(target_status_reason), ''), 'release_if_owner'),
        revision = revision + 1
    where property_id = target_property_id
    returning * into result;

    return result;
end;
$$;

create or replace function public.rebuild_property_status(
    target_property_id uuid,
    target_status_reason text default 'rebuild'
)
returns public.property_status
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid := public.property_status_assert_writer(target_property_id);
    actor_id uuid := auth.uid();
    occupancy_row public.property_session_occupancy%rowtype;
    draft_session public.sessions%rowtype;
    pending_session public.sessions%rowtype;
    exported_session public.sessions%rowtype;
    result public.property_status%rowtype;
begin
    select session_row.*
    into draft_session
    from public.sessions session_row
    where session_row.org_id = target_org_id
      and session_row.property_id = target_property_id
      and session_row.deleted_at is null
      and session_row.status = 'draft'
      and coalesce(session_row.is_sealed, false) = false
      and exists (
          select 1
          from public.shots shot
          where shot.session_id = session_row.id
            and shot.org_id = target_org_id
            and shot.deleted_at is null
      )
    order by session_row.updated_at desc, session_row.started_at desc nulls last, session_row.id
    limit 1;

    if draft_session.id is not null then
        insert into public.property_status (
            property_id,
            org_id,
            status,
            active_session_id,
            draft_session_id,
            owner_user_id,
            owner_device_id,
            heartbeat_at,
            updated_by,
            status_reason
        )
        values (
            target_property_id,
            target_org_id,
            'draft',
            draft_session.id,
            draft_session.id,
            draft_session.locked_by_user_id,
            nullif(btrim(coalesce(draft_session.locked_by_device_id, '')), ''),
            draft_session.locked_at,
            actor_id,
            coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':draft'
        )
        on conflict (property_id) do update
        set org_id = excluded.org_id,
            status = excluded.status,
            active_session_id = excluded.active_session_id,
            draft_session_id = excluded.draft_session_id,
            pending_export_session_id = null,
            owner_user_id = excluded.owner_user_id,
            owner_device_id = excluded.owner_device_id,
            heartbeat_at = excluded.heartbeat_at,
            updated_by = excluded.updated_by,
            status_reason = excluded.status_reason,
            revision = public.property_status.revision + 1
        returning * into result;

        return result;
    end if;

    select *
    into occupancy_row
    from public.property_session_occupancy occupancy
    where occupancy.property_id = target_property_id
      and occupancy.org_id = target_org_id
      and (
          occupancy.occupied_by_user_id is not null
          or nullif(btrim(coalesce(occupancy.occupied_by_device_id, '')), '') is not null
          or occupancy.occupied_at is not null
      )
      and (
          occupancy.occupied_at is null
          or occupancy.occupied_at >= timezone('utc', now()) - interval '30 minutes'
      )
    order by occupancy.updated_at desc
    limit 1;

    if occupancy_row.property_id is not null then
        insert into public.property_status (
            property_id,
            org_id,
            status,
            active_session_id,
            owner_user_id,
            owner_device_id,
            heartbeat_at,
            updated_by,
            status_reason
        )
        values (
            target_property_id,
            target_org_id,
            'occupied',
            null,
            occupancy_row.occupied_by_user_id,
            nullif(btrim(coalesce(occupancy_row.occupied_by_device_id, '')), ''),
            occupancy_row.occupied_at,
            actor_id,
            coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':occupancy'
        )
        on conflict (property_id) do update
        set org_id = excluded.org_id,
            status = excluded.status,
            active_session_id = excluded.active_session_id,
            draft_session_id = null,
            pending_export_session_id = null,
            owner_user_id = excluded.owner_user_id,
            owner_device_id = excluded.owner_device_id,
            heartbeat_at = excluded.heartbeat_at,
            updated_by = excluded.updated_by,
            status_reason = excluded.status_reason,
            revision = public.property_status.revision + 1
        returning * into result;

        return result;
    end if;

    select session_row.*
    into pending_session
    from public.sessions session_row
    where session_row.org_id = target_org_id
      and session_row.property_id = target_property_id
      and session_row.deleted_at is null
      and session_row.status = 'completed'
      and coalesce(session_row.is_sealed, false) = true
      and session_row.first_delivered_at is null
    order by session_row.completed_at desc nulls last, session_row.updated_at desc, session_row.id
    limit 1;

    if pending_session.id is not null then
        return public.set_property_status_pending_export(
            target_property_id,
            pending_session.id,
            null,
            coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':pending_export'
        );
    end if;

    select session_row.*
    into exported_session
    from public.sessions session_row
    where session_row.org_id = target_org_id
      and session_row.property_id = target_property_id
      and session_row.deleted_at is null
      and (
          session_row.first_delivered_at is not null
          or session_row.exported_at is not null
      )
    order by coalesce(session_row.first_delivered_at, session_row.exported_at, session_row.updated_at) desc,
             session_row.id
    limit 1;

    if exported_session.id is not null then
        return public.set_property_status_exported(
            target_property_id,
            exported_session.id,
            null,
            coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':exported'
        );
    end if;

    insert into public.property_status (
        property_id,
        org_id,
        status,
        updated_by,
        status_reason
    )
    values (
        target_property_id,
        target_org_id,
        'idle',
        actor_id,
        coalesce(nullif(btrim(target_status_reason), ''), 'rebuild') || ':idle'
    )
    on conflict (property_id) do update
    set org_id = excluded.org_id,
        status = 'idle',
        active_session_id = null,
        draft_session_id = null,
        pending_export_session_id = null,
        owner_user_id = null,
        owner_device_id = null,
        heartbeat_at = null,
        updated_by = excluded.updated_by,
        status_reason = excluded.status_reason,
        revision = public.property_status.revision + 1
    returning * into result;

    return result;
end;
$$;

revoke all on function public.property_status_actor_can_write(uuid, uuid) from public;
revoke all on function public.property_status_actor_owns(uuid, text, text) from public;
revoke all on function public.property_status_is_stale(text, timestamptz) from public;
revoke all on function public.property_status_session_matches_property(uuid, uuid, uuid) from public;
revoke all on function public.property_status_property_org(uuid) from public;
revoke all on function public.property_status_assert_writer(uuid) from public;
revoke all on function public.property_status_assert_not_blocked(public.property_status, text, boolean) from public;

revoke all on function public.claim_property_status(uuid, uuid, text, text) from public;
revoke all on function public.heartbeat_property_status(uuid, text, text) from public;
revoke all on function public.promote_property_status_draft(uuid, uuid, text, text) from public;
revoke all on function public.set_property_status_pending_export(uuid, uuid, text, text) from public;
revoke all on function public.set_property_status_exported(uuid, uuid, text, text) from public;
revoke all on function public.release_property_status_if_owner(uuid, text, text) from public;
revoke all on function public.rebuild_property_status(uuid, text) from public;

grant execute on function public.claim_property_status(uuid, uuid, text, text) to authenticated;
grant execute on function public.heartbeat_property_status(uuid, text, text) to authenticated;
grant execute on function public.promote_property_status_draft(uuid, uuid, text, text) to authenticated;
grant execute on function public.set_property_status_pending_export(uuid, uuid, text, text) to authenticated;
grant execute on function public.set_property_status_exported(uuid, uuid, text, text) to authenticated;
grant execute on function public.release_property_status_if_owner(uuid, text, text) to authenticated;
grant execute on function public.rebuild_property_status(uuid, text) to authenticated;

-- Source: scout-site@ef46714:supabase/migrations/202609280005_organization_retention_purge.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Purge an organization only after its 90-day grace period, once all customer
-- memberships are inactive. Storage is removed first by the service worker;
-- the final database deletion is atomic and refuses to run while files remain.
-- This migration does not schedule the worker or delete any existing data.

-- Serialize a returning customer with the worker's claim/finalize operations.
create or replace function public.guard_purging_organization_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    retention_status text;
begin
    if new.deleted_at is not null then return new; end if;
    select schedule.status into retention_status
      from public.organization_retention_schedule schedule
     where schedule.org_id = new.org_id
     for update;
    if retention_status = 'purging' then
        raise exception 'Organization data removal is already in progress';
    end if;
    if retention_status = 'scheduled' then
        update public.organization_retention_schedule
           set status = 'canceled', updated_at = timezone('utc', now()), last_error = null
         where org_id = new.org_id;
    end if;
    return new;
end;
$$;

drop trigger if exists guard_purging_organization_membership on public.org_memberships;
create trigger guard_purging_organization_membership
    before insert or update of org_id, user_id, deleted_at
    on public.org_memberships for each row
    execute function public.guard_purging_organization_membership();

create or replace function public.claim_next_organization_purge(
    trusted_admin_emails text[] default '{}'::text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    claimed_org_id uuid;
begin
    if cardinality(trusted_admin_emails) = 0 then
        raise exception 'Platform admin exclusion list is required';
    end if;
    update public.organization_retention_schedule schedule
       set status = 'purging', updated_at = timezone('utc', now()), last_error = null
     where schedule.org_id = (
         select candidate.org_id
           from public.organization_retention_schedule candidate
          where ((candidate.status = 'scheduled'
                  and candidate.purge_after <= timezone('utc', now()))
              or (candidate.status = 'purging'
                  and candidate.updated_at < timezone('utc', now()) - interval '15 minutes'))
            and not exists (
                select 1 from public.org_memberships member
                join public.users_profile profile on profile.id = member.user_id
                where member.org_id = candidate.org_id
                  and member.deleted_at is null
                  and lower(coalesce(profile.email, '')) <> all(trusted_admin_emails)
            )
          order by case when candidate.status = 'scheduled' then 0 else 1 end,
                   candidate.purge_after
          for update skip locked
          limit 1
     )
    returning schedule.org_id into claimed_org_id;
    return claimed_org_id;
end;
$$;

-- Exact storage rows, including unindexed objects under the reviewed prefixes.
-- Return an unfamiliar bucket to the worker so it fails closed.
create or replace function public.organization_purge_storage_objects(target_org_id uuid)
returns table (bucket_id text, object_name text)
language sql
security definer
set search_path = public
as $$
    select object_row.bucket_id, object_row.name
      from storage.objects object_row
     where object_row.name like 'orgs/' || target_org_id::text || '/%'
        or object_row.name like 'punchlist-completions/orgs/' || target_org_id::text || '/%'
        or exists (
            select 1 from public.sessions session_row
             where session_row.org_id = target_org_id
               and object_row.name like 'sessions/' || session_row.id::text || '/%'
        )
        or exists (
            select 1 from public.shots shot
             where shot.org_id = target_org_id
               and shot.storage_bucket = object_row.bucket_id
               and shot.storage_path = object_row.name
        )
        or exists (
            select 1 from public.session_snapshots snapshot
             where snapshot.org_id = target_org_id
               and snapshot.payload_storage_bucket = object_row.bucket_id
               and snapshot.payload_storage_path = object_row.name
        )
        or exists (
            select 1 from public.punchlist_activity activity
             where activity.org_id = target_org_id
               and activity.storage_bucket = object_row.bucket_id
               and activity.storage_path = object_row.name
        )
        or exists (
            select 1 from public.report_package_files file_row
             where file_row.org_id = target_org_id
               and file_row.storage_bucket = object_row.bucket_id
               and file_row.storage_path = object_row.name
        )
        or exists (
            select 1 from public.temporary_exports export_row
             where export_row.org_id = target_org_id
               and export_row.storage_bucket = object_row.bucket_id
               and export_row.storage_path = object_row.name
        )
     order by object_row.bucket_id, object_row.name;
$$;

create or replace function public.finish_organization_purge(
    target_org_id uuid,
    trusted_admin_emails text[] default '{}'::text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    retention_row public.organization_retention_schedule%rowtype;
    table_name text;
    tables_to_delete text[] := array[
        'report_package_email_notifications', 'report_package_files',
        'temporary_exports', 'observation_updates', 'punchlist_activity',
        'report_packages', 'session_events', 'session_snapshots',
        'observations', 'shots', 'portal_invite_property_grants',
        'property_access_grants', 'property_session_occupancy',
        'property_status', 'sessions', 'portal_invites', 'org_invitations',
        'org_memberships', 'report_email_user_preferences',
        'report_email_org_settings', 'properties'
    ];
begin
    if cardinality(trusted_admin_emails) = 0 then
        raise exception 'Platform admin exclusion list is required';
    end if;
    select * into retention_row
      from public.organization_retention_schedule
     where org_id = target_org_id for update;
    if not found or retention_row.status <> 'purging'
       or retention_row.purge_after > timezone('utc', now()) then
        raise exception 'Organization is not eligible for purge';
    end if;
    if exists (
        select 1 from public.org_memberships member
        join public.users_profile profile on profile.id = member.user_id
        where member.org_id = target_org_id
          and member.deleted_at is null
          and lower(coalesce(profile.email, '')) <> all(trusted_admin_emails)
    ) then
        raise exception 'Organization has an active customer';
    end if;
    if exists (select 1 from public.organization_purge_storage_objects(target_org_id)) then
        raise exception 'Organization Storage objects remain';
    end if;
    foreach table_name in array tables_to_delete loop
        execute format('delete from public.%I where org_id = $1', table_name)
            using target_org_id;
    end loop;
    delete from public.orgs where id = target_org_id;
end;
$$;

revoke all on function public.guard_purging_organization_membership() from public, anon, authenticated;
revoke all on function public.claim_next_organization_purge(text[]) from public, anon, authenticated;
revoke all on function public.organization_purge_storage_objects(uuid) from public, anon, authenticated;
revoke all on function public.finish_organization_purge(uuid, text[]) from public, anon, authenticated;
grant execute on function public.claim_next_organization_purge(text[]) to service_role;
grant execute on function public.organization_purge_storage_objects(uuid) to service_role;
grant execute on function public.finish_organization_purge(uuid, text[]) to service_role;

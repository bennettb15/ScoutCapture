-- Source: scout-site@ef46714:supabase/migrations/202609280001_account_deletion_requests.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Account deletion is distinct from organization record retention. The request
-- stage removes data access immediately and queues irreversible cleanup.
create table if not exists public.account_deletion_requests (
    id uuid primary key default gen_random_uuid(),
    user_id uuid unique references auth.users(id) on delete set null,
    request_email text,
    request_full_name text,
    status text not null default 'pending' check (status in ('pending', 'processing', 'completed', 'failed')),
    requested_at timestamptz not null default timezone('utc', now()),
    started_at timestamptz,
    completed_at timestamptz,
    last_error text
);

create index if not exists idx_account_deletion_requests_work
    on public.account_deletion_requests (requested_at)
    where status in ('pending', 'failed');

alter table public.account_deletion_requests enable row level security;
revoke all on public.account_deletion_requests from anon, authenticated;
grant select, insert, update, delete on public.account_deletion_requests to service_role;

create table if not exists public.organization_retention_schedule (
    org_id uuid primary key references public.orgs(id) on delete cascade,
    inactive_since timestamptz not null,
    purge_after timestamptz not null,
    status text not null default 'scheduled' check (status in ('scheduled', 'purging', 'purged', 'canceled')),
    last_error text,
    updated_at timestamptz not null default timezone('utc', now())
);

alter table public.organization_retention_schedule enable row level security;
revoke all on public.organization_retention_schedule from anon, authenticated;
grant select, insert, update, delete on public.organization_retention_schedule to service_role;

create or replace function public.request_user_account_deletion(
    target_user_id uuid,
    trusted_admin_emails text[] default '{}'::text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    target_email text;
    target_full_name text;
    request_id uuid;
    affected_org_id uuid;
    request_time timestamptz := timezone('utc', now());
begin
    if cardinality(trusted_admin_emails) = 0 then
        raise exception 'Platform admin exclusion list is required';
    end if;
    select email into target_email from auth.users where id = target_user_id;
    if not found then
        raise exception 'Account not found';
    end if;
    if lower(target_email) = any(trusted_admin_emails) then
        raise exception 'Transfer platform administration before deleting this account';
    end if;
    if exists (
        select 1
          from public.org_memberships member
         where member.user_id = target_user_id
           and member.deleted_at is null
           and member.role = 'owner'
           and not exists (
               select 1 from public.org_memberships other_owner
                where other_owner.org_id = member.org_id
                  and other_owner.user_id <> target_user_id
                  and other_owner.deleted_at is null
                  and other_owner.role = 'owner'
           )
    ) then
        raise exception 'Transfer sole organization ownership before deleting this account';
    end if;

    select full_name into target_full_name
      from public.users_profile where id = target_user_id;

    insert into public.account_deletion_requests (user_id, request_email, request_full_name)
    values (target_user_id, target_email, target_full_name)
    on conflict (user_id) do update
        set request_email = excluded.request_email,
            request_full_name = excluded.request_full_name
    returning id into request_id;

    -- Access is removed in this transaction, before any asynchronous cleanup.
    update public.org_memberships
       set deleted_at = coalesce(deleted_at, request_time), updated_by = null
     where user_id = target_user_id and deleted_at is null;

    if to_regclass('public.report_package_email_notifications') is not null then
        execute 'update public.report_package_email_notifications set status = ''skipped'' where recipient_user_id = $1 and status in (''pending'', ''failed'')'
            using target_user_id;
    end if;

    for affected_org_id in
        select distinct org_id from public.org_memberships where user_id = target_user_id
    loop
        if not exists (
            select 1
              from public.org_memberships member
              join public.users_profile profile on profile.id = member.user_id
             where member.org_id = affected_org_id
               and member.deleted_at is null
               and lower(coalesce(profile.email, '')) <> all(trusted_admin_emails)
        ) then
            insert into public.organization_retention_schedule (
                org_id, inactive_since, purge_after, status, updated_at
            ) values (
                affected_org_id, request_time, request_time + interval '90 days', 'scheduled', request_time
            )
            on conflict (org_id) do update
                set inactive_since = case
                        when public.organization_retention_schedule.status = 'scheduled'
                            then public.organization_retention_schedule.inactive_since
                        else excluded.inactive_since
                    end,
                    purge_after = case
                        when public.organization_retention_schedule.status = 'scheduled'
                            then public.organization_retention_schedule.purge_after
                        else excluded.purge_after
                    end,
                    status = 'scheduled', updated_at = request_time;
        end if;
    end loop;

    -- Profile fields stop appearing in portal attribution immediately, while
    -- the Auth row remains until the resumable hard-delete worker finishes.
    update public.users_profile
       set email = null, full_name = null, avatar_url = null,
           deleted_at = coalesce(deleted_at, request_time), updated_by = null
     where id = target_user_id;

    return request_id;
end;
$$;

revoke all on function public.request_user_account_deletion(uuid, text[]) from public, anon, authenticated;
grant execute on function public.request_user_account_deletion(uuid, text[]) to service_role;

-- Keep a durable transfer journal so a failed Storage API operation can resume
-- without discarding an organization's original media.
create table if not exists public.account_deletion_storage_transfers (
    request_id uuid not null references public.account_deletion_requests(id) on delete cascade,
    bucket_id text not null,
    object_name text not null,
    temporary_name text not null,
    status text not null default 'pending' check (status in ('pending', 'complete')),
    primary key (request_id, bucket_id, object_name)
);

alter table public.account_deletion_storage_transfers enable row level security;
revoke all on public.account_deletion_storage_transfers from anon, authenticated;
grant select, insert, update, delete on public.account_deletion_storage_transfers to service_role;

create or replace function public.account_deletion_owned_objects(target_user_id uuid)
returns table (bucket_id text, object_name text)
language sql
security definer
set search_path = public
as $$
    select object_row.bucket_id, object_row.name
      from storage.objects object_row
     where object_row.owner_id = target_user_id::text
        or object_row.owner::text = target_user_id::text
     order by object_row.bucket_id, object_row.name;
$$;

revoke all on function public.account_deletion_owned_objects(uuid) from public, anon, authenticated;
grant execute on function public.account_deletion_owned_objects(uuid) to service_role;

alter table public.org_invitations alter column invited_by drop not null;
alter table public.property_access_grants alter column granted_by drop not null;
alter table public.punchlist_activity alter column created_by drop not null;

-- Run only after every Storage object owned by the user has been safely
-- transferred through the Storage API. The procedure never deletes org data.
create or replace function public.prepare_user_account_hard_delete(target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    target_email text;
    referenced_table text;
    referenced_column text;
    required_reference_exists boolean;
    fk record;
begin
    if not exists (
        select 1 from public.account_deletion_requests request
        where request.user_id = target_user_id
          and request.status in ('pending', 'processing', 'failed')
    ) then
        raise exception 'Deletion request not found';
    end if;

    if exists (
        select 1 from storage.objects object_row
        where object_row.owner_id = target_user_id::text
           or object_row.owner::text = target_user_id::text
    ) then
        raise exception 'Storage ownership must be transferred before Auth deletion';
    end if;

    select email into target_email from auth.users where id = target_user_id;

    -- Personal invitation and email delivery records have no retained
    -- organization-document value after the account is removed.
    delete from public.portal_invites where lower(email) = lower(target_email);
    delete from public.org_invitations where lower(invitee_email) = lower(target_email);
    if to_regclass('public.report_package_email_notifications') is not null then
        execute 'delete from public.report_package_email_notifications where recipient_user_id = $1 or lower(recipient_email) = lower($2)'
            using target_user_id, target_email;
    end if;

    -- Release live locks owned by the departing user. property_status has
    -- constraints requiring an owner while occupied or in draft state.
    update public.property_status
       set status = case when status in ('occupied', 'draft') then 'idle' else status end,
           active_session_id = case when status in ('occupied', 'draft') then null else active_session_id end,
           draft_session_id = case when status in ('occupied', 'draft') then null else draft_session_id end,
           owner_user_id = null,
           owner_device_id = null,
           status_reason = 'account_deleted'
     where owner_user_id = target_user_id;

    update public.property_session_occupancy
       set occupied_by_user_id = null, occupied_by_device_id = null, occupied_at = null
     where occupied_by_user_id = target_user_id;

    update public.sessions
       set locked_by_user_id = null, locked_by_device_id = null, locked_at = null
     where locked_by_user_id = target_user_id;

    -- Remove direct access rows. Other FK columns are authorship/update
    -- pointers on organization-owned records and become anonymous.
    delete from public.property_access_grants where user_id = target_user_id;
    delete from public.org_memberships where user_id = target_user_id;
    if to_regclass('public.report_email_user_preferences') is not null then
        execute 'delete from public.report_email_user_preferences where user_id = $1'
            using target_user_id;
    end if;

    for fk in
        select child_namespace.nspname as schema_name,
               child_table.relname as table_name,
               child_column.attname as column_name,
               child_column.attnotnull as required
          from pg_constraint constraint_row
          join pg_class child_table on child_table.oid = constraint_row.conrelid
          join pg_namespace child_namespace on child_namespace.oid = child_table.relnamespace
          join pg_attribute child_column
            on child_column.attrelid = child_table.oid
           and child_column.attnum = constraint_row.conkey[1]
         where constraint_row.contype = 'f'
           and constraint_row.confrelid = 'public.users_profile'::regclass
           and array_length(constraint_row.conkey, 1) = 1
    loop
        referenced_table := format('%I.%I', fk.schema_name, fk.table_name);
        referenced_column := format('%I', fk.column_name);
        if fk.required then
            -- Known required access and notification rows were removed above.
            -- A new required FK must receive an explicit retention policy.
            execute format('select exists (select 1 from %s where %s = $1)', referenced_table, referenced_column)
                into strict required_reference_exists using target_user_id;
            if required_reference_exists then
                raise exception 'Unreviewed required account reference %.%', referenced_table, referenced_column;
            end if;
        else
            execute format('update %s set %s = null where %s = $1', referenced_table, referenced_column, referenced_column)
                using target_user_id;
        end if;
    end loop;

    -- Fail closed if a future multi-column FK needs an explicit policy.
    if exists (
        select 1 from pg_constraint constraint_row
         where constraint_row.contype = 'f'
           and constraint_row.confrelid = 'public.users_profile'::regclass
           and array_length(constraint_row.conkey, 1) <> 1
    ) then
        raise exception 'Unreviewed multi-column user-profile reference';
    end if;
end;
$$;

revoke all on function public.prepare_user_account_hard_delete(uuid) from public, anon, authenticated;
grant execute on function public.prepare_user_account_hard_delete(uuid) to service_role;

-- Claim one request atomically so overlapping scheduled invocations do not
-- process the same account. A stale processing claim can be retried.
create or replace function public.claim_next_account_deletion()
returns table (
    id uuid,
    user_id uuid,
    request_email text,
    request_full_name text,
    status text,
    started_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    return query
    update public.account_deletion_requests request
       set status = 'processing',
           started_at = timezone('utc', now()),
           last_error = null
     where request.id = (
         select candidate.id
           from public.account_deletion_requests candidate
          where candidate.status in ('pending', 'failed')
             or (candidate.status = 'processing'
                 and candidate.started_at < timezone('utc', now()) - interval '15 minutes')
          order by case candidate.status
                       when 'pending' then 0
                       when 'failed' then 1
                       else 2
                   end, candidate.requested_at
          for update skip locked
          limit 1
     )
    returning request.id, request.user_id, request.request_email,
              request.request_full_name, request.status, request.started_at;
end;
$$;

revoke all on function public.claim_next_account_deletion() from public, anon, authenticated;
grant execute on function public.claim_next_account_deletion() to service_role;

-- Reconcile the 90-day clock for membership changes outside account deletion.
-- A previously active customer membership is required so a newly created,
-- admin-only organization is not scheduled before its first customer joins.
create or replace function public.reconcile_org_retention_schedule(
    trusted_admin_emails text[] default '{}'::text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if cardinality(trusted_admin_emails) = 0 then
        raise exception 'Platform admin exclusion list is required';
    end if;
    update public.organization_retention_schedule schedule
       set status = 'canceled', updated_at = timezone('utc', now()), last_error = null
     where schedule.status = 'scheduled'
       and exists (
           select 1
             from public.org_memberships member
             join public.users_profile profile on profile.id = member.user_id
            where member.org_id = schedule.org_id
              and member.deleted_at is null
              and lower(coalesce(profile.email, '')) <> all(trusted_admin_emails)
       );

    insert into public.organization_retention_schedule (
        org_id, inactive_since, purge_after, status, updated_at
    )
    select org.id, timezone('utc', now()), timezone('utc', now()) + interval '90 days',
           'scheduled', timezone('utc', now())
      from public.orgs org
     where org.deleted_at is null
       and exists (
           select 1
             from public.org_memberships member
             join public.users_profile profile on profile.id = member.user_id
            where member.org_id = org.id
              and lower(coalesce(profile.email, '')) <> all(trusted_admin_emails)
       )
       and not exists (
           select 1
             from public.org_memberships member
             join public.users_profile profile on profile.id = member.user_id
            where member.org_id = org.id
              and member.deleted_at is null
              and lower(coalesce(profile.email, '')) <> all(trusted_admin_emails)
       )
    on conflict (org_id) do update
        set inactive_since = excluded.inactive_since,
            purge_after = excluded.purge_after,
            status = 'scheduled',
            updated_at = excluded.updated_at,
            last_error = null
      where public.organization_retention_schedule.status = 'canceled';
end;
$$;

revoke all on function public.reconcile_org_retention_schedule(text[]) from public, anon, authenticated;
grant execute on function public.reconcile_org_retention_schedule(text[]) to service_role;

-- A cached JWT or admin reinvite cannot restore a deletion-pending profile
-- or membership before the Auth hard delete completes.
create or replace function public.guard_deleting_account_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (
        select 1 from public.account_deletion_requests request
         where request.user_id = new.id
           and request.status in ('pending', 'processing', 'failed')
    ) and (
        new.email is not null or new.full_name is not null
        or new.avatar_url is not null or new.deleted_at is null
    ) then
        raise exception 'Account deletion is in progress';
    end if;
    return new;
end;
$$;

drop trigger if exists guard_deleting_account_profile on public.users_profile;
create trigger guard_deleting_account_profile
    before insert or update on public.users_profile
    for each row execute function public.guard_deleting_account_profile();

create or replace function public.guard_deleting_account_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.deleted_at is null and exists (
        select 1 from public.account_deletion_requests request
         where request.user_id = new.user_id
           and request.status in ('pending', 'processing', 'failed')
    ) then
        raise exception 'Account deletion is in progress';
    end if;
    return new;
end;
$$;

drop trigger if exists guard_deleting_account_membership on public.org_memberships;
create trigger guard_deleting_account_membership
    before insert or update on public.org_memberships
    for each row execute function public.guard_deleting_account_membership();

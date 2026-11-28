-- Source: scout-site@ef46714:supabase/migrations/202609280003_account_deletion_metadata_redaction.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- Redact account attribution that can live in organization-owned JSON/text
-- after the Auth user and profile are removed. Business records remain.
create or replace function public.account_deletion_redact_text(
    source_text text,
    target_email text,
    target_full_name text default null
)
returns text
language plpgsql
immutable
as $$
declare
    remainder text := source_text;
    output_text text := '';
    match_position integer;
begin
    if source_text is null or nullif(target_email, '') is null then
        return source_text;
    end if;
    if nullif(target_full_name, '') is not null
       and lower(trim(source_text)) = lower(trim(target_full_name)) then
        return 'Deleted user';
    end if;
    loop
        match_position := position(lower(target_email) in lower(remainder));
        exit when match_position = 0;
        output_text := output_text || substring(remainder from 1 for match_position - 1) || 'Deleted user';
        remainder := substring(remainder from match_position + char_length(target_email));
    end loop;
    return output_text || remainder;
end;
$$;

create or replace function public.account_deletion_redact_jsonb(
    source_value jsonb,
    target_email text,
    target_user_id uuid,
    target_full_name text default null
)
returns jsonb
language plpgsql
immutable
as $$
declare
    result_value jsonb;
    entry_key text;
    entry_value jsonb;
    plain_text text;
begin
    case jsonb_typeof(source_value)
        when 'object' then
            result_value := '{}'::jsonb;
            for entry_key, entry_value in select key, value from jsonb_each(source_value) loop
                result_value := result_value || jsonb_build_object(
                    entry_key,
                    public.account_deletion_redact_jsonb(
                        entry_value, target_email, target_user_id, target_full_name
                    )
                );
            end loop;
            return result_value;
        when 'array' then
            result_value := '[]'::jsonb;
            for entry_value in select value from jsonb_array_elements(source_value) loop
                result_value := result_value || jsonb_build_array(
                    public.account_deletion_redact_jsonb(
                        entry_value, target_email, target_user_id, target_full_name
                    )
                );
            end loop;
            return result_value;
        when 'string' then
            plain_text := source_value #>> '{}';
            if lower(plain_text) = lower(target_user_id::text) then
                return 'null'::jsonb;
            end if;
            return to_jsonb(public.account_deletion_redact_text(
                plain_text, target_email, target_full_name
            ));
        else
            return source_value;
    end case;
end;
$$;

revoke all on function public.account_deletion_redact_text(text, text, text)
    from public, anon, authenticated;
revoke all on function public.account_deletion_redact_jsonb(jsonb, text, uuid, text)
    from public, anon, authenticated;

create or replace function public.redact_user_account_metadata(target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    target_email text;
    target_full_name text;
begin
    select request_email, request_full_name
      into target_email, target_full_name
      from public.account_deletion_requests
     where user_id = target_user_id
       and status in ('pending', 'processing', 'failed');
    if not found or nullif(target_email, '') is null then
        raise exception 'Account deletion request is missing attribution details';
    end if;

    update public.session_events event_row
       set payload = public.account_deletion_redact_jsonb(
           event_row.payload, target_email, target_user_id, target_full_name
       )
     where event_row.org_id in (
         select org_id from public.org_memberships where user_id = target_user_id
     )
       and event_row.payload is distinct from public.account_deletion_redact_jsonb(
           event_row.payload, target_email, target_user_id, target_full_name
       );

    update public.session_snapshots snapshot
       set manifest = public.account_deletion_redact_jsonb(
           snapshot.manifest, target_email, target_user_id, target_full_name
       ), updated_by = null
     where snapshot.org_id in (
         select org_id from public.org_memberships where user_id = target_user_id
     )
       and snapshot.manifest is distinct from public.account_deletion_redact_jsonb(
           snapshot.manifest, target_email, target_user_id, target_full_name
       );

    if to_regclass('public.report_packages') is not null then
        execute $query$
            update public.report_packages package
               set manifest = public.account_deletion_redact_jsonb(
                       package.manifest, $1, $2, $3
                   ),
                   validation_summary = public.account_deletion_redact_jsonb(
                       package.validation_summary, $1, $2, $3
                   ),
                   weather_metadata = public.account_deletion_redact_jsonb(
                       package.weather_metadata, $1, $2, $3
                   )
             where package.org_id in (
                 select org_id from public.org_memberships where user_id = $2
             )
               and (
                   package.manifest is distinct from public.account_deletion_redact_jsonb(package.manifest, $1, $2, $3)
                   or package.validation_summary is distinct from public.account_deletion_redact_jsonb(package.validation_summary, $1, $2, $3)
                   or package.weather_metadata is distinct from public.account_deletion_redact_jsonb(package.weather_metadata, $1, $2, $3)
               )
        $query$ using target_email, target_user_id, target_full_name;
    end if;

    update public.properties property_row
       set client_email = case
               when lower(property_row.client_email) = lower(target_email) then null
               else property_row.client_email end,
           client_name = case
               when target_full_name is not null
                    and lower(property_row.client_name) = lower(target_full_name) then null
               else property_row.client_name end
     where property_row.org_id in (
         select org_id from public.org_memberships where user_id = target_user_id
     )
       and (lower(property_row.client_email) = lower(target_email)
            or (target_full_name is not null
                and lower(property_row.client_name) = lower(target_full_name)));

    update public.observations observation
       set title = public.account_deletion_redact_text(observation.title, target_email, target_full_name),
           detail = public.account_deletion_redact_text(observation.detail, target_email, target_full_name)
     where observation.org_id in (
         select org_id from public.org_memberships where user_id = target_user_id
     )
       and (position(lower(target_email) in lower(coalesce(observation.title, ''))) > 0
            or position(lower(target_email) in lower(coalesce(observation.detail, ''))) > 0);

    update public.observation_updates update_row
       set message = public.account_deletion_redact_text(update_row.message, target_email, target_full_name),
           note = public.account_deletion_redact_text(update_row.note, target_email, target_full_name)
     where update_row.org_id in (
         select org_id from public.org_memberships where user_id = target_user_id
     )
       and (position(lower(target_email) in lower(coalesce(update_row.message, ''))) > 0
            or position(lower(target_email) in lower(coalesce(update_row.note, ''))) > 0);

    update public.punchlist_activity activity
       set note = public.account_deletion_redact_text(activity.note, target_email, target_full_name),
           filename = public.account_deletion_redact_text(activity.filename, target_email, target_full_name)
     where activity.org_id in (
         select org_id from public.org_memberships where user_id = target_user_id
     )
       and (position(lower(target_email) in lower(coalesce(activity.note, ''))) > 0
            or position(lower(target_email) in lower(coalesce(activity.filename, ''))) > 0);

    if to_regclass('public.report_package_files') is not null then
        execute $query$
            update public.report_package_files file_row
               set filename = public.account_deletion_redact_text(
                   file_row.filename, $1, $3
               )
             where file_row.org_id in (
                 select org_id from public.org_memberships where user_id = $2
             )
               and position(lower($1) in lower(file_row.filename)) > 0
        $query$ using target_email, target_user_id, target_full_name;
    end if;

    update public.temporary_exports export_row
       set filename = public.account_deletion_redact_text(
           export_row.filename, target_email, target_full_name
       )
     where export_row.org_id in (
         select org_id from public.org_memberships where user_id = target_user_id
     )
       and position(lower(target_email) in lower(coalesce(export_row.filename, ''))) > 0;
end;
$$;

revoke all on function public.redact_user_account_metadata(uuid)
    from public, anon, authenticated;
grant execute on function public.redact_user_account_metadata(uuid) to service_role;

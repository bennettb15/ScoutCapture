-- Schema-only reconstruction from scout-dev public catalog on 2026-11-27.
-- No customer rows or credentials are copied.
-- These report artifacts were present in the shared backend but absent from both repositories.

create table public.report_packages (
    id uuid default gen_random_uuid() not null,
    org_id uuid not null,
    property_id uuid not null,
    session_id uuid not null,
    snapshot_id uuid not null,
    status text default 'queued'::text not null,
    generation_trigger text default 'session_completed'::text not null,
    idempotency_key text not null,
    session_completed_at timestamp with time zone not null,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    attempt_count integer default 0 not null,
    locked_at timestamp with time zone,
    locked_by text,
    last_error text,
    renderer_version text not null,
    report_contract_version text,
    media_preparer_version text,
    stamp_visual_version text,
    logo_asset_sha256 text,
    raw_session_json_sha256 text,
    snapshot_payload_sha256 text,
    report_input_sha256 text,
    prepared_media_manifest_sha256 text,
    report_plan_sha256 text,
    weather_summary text,
    weather_source text,
    weather_metadata jsonb default '{}'::jsonb not null,
    validation_summary jsonb default '{}'::jsonb not null,
    manifest jsonb default '{}'::jsonb not null,
    storage_pruned_at timestamp with time zone,
    created_at timestamp with time zone default timezone('utc'::text, now()) not null,
    updated_at timestamp with time zone default timezone('utc'::text, now()) not null,
    revision bigint default 1 not null,
    deleted_at timestamp with time zone
);

create table public.temporary_exports (
    id uuid default gen_random_uuid() not null,
    org_id uuid not null,
    property_id uuid not null,
    session_id uuid not null,
    snapshot_id uuid not null,
    artifact_type text default 'stamped_jpg_zip'::text not null,
    status text default 'queued'::text not null,
    cache_key text not null,
    requested_by uuid,
    requested_at timestamp with time zone default timezone('utc'::text, now()) not null,
    expires_at timestamp with time zone,
    storage_bucket text default 'scoutcapture-deliverables'::text not null,
    storage_path text,
    filename text,
    mime_type text default 'application/zip'::text not null,
    byte_size bigint,
    sha256 text,
    attempt_count integer default 0 not null,
    locked_at timestamp with time zone,
    locked_by text,
    last_error text,
    created_at timestamp with time zone default timezone('utc'::text, now()) not null,
    updated_at timestamp with time zone default timezone('utc'::text, now()) not null,
    revision bigint default 1 not null,
    deleted_at timestamp with time zone
);

create table public.report_package_files (
    id uuid default gen_random_uuid() not null,
    package_id uuid not null,
    org_id uuid not null,
    property_id uuid not null,
    session_id uuid not null,
    snapshot_id uuid not null,
    report_type text not null,
    storage_bucket text default 'scoutcapture-deliverables'::text not null,
    storage_path text not null,
    filename text not null,
    mime_type text default 'application/pdf'::text not null,
    byte_size bigint not null,
    sha256 text not null,
    page_count integer not null,
    created_at timestamp with time zone default timezone('utc'::text, now()) not null,
    updated_at timestamp with time zone default timezone('utc'::text, now()) not null,
    revision bigint default 1 not null,
    storage_deleted_at timestamp with time zone,
    deleted_at timestamp with time zone
);

CREATE OR REPLACE FUNCTION public.report_artifact_row_matches_parents(target_org_id uuid, target_property_id uuid, target_session_id uuid, target_snapshot_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select exists (
        select 1
        from public.session_snapshots snapshot
        where snapshot.id = target_snapshot_id
          and snapshot.org_id = target_org_id
          and snapshot.property_id = target_property_id
          and snapshot.session_id = target_session_id
          and snapshot.snapshot_kind = 'completed'
          and snapshot.is_sealed = true
          and snapshot.deleted_at is null
    );
$function$;

CREATE OR REPLACE FUNCTION public.report_package_file_expected_storage_path(target_org_id uuid, target_property_id uuid, target_session_id uuid, target_package_id uuid, target_report_type text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select 'orgs/' || lower(target_org_id::text)
        || '/properties/' || lower(target_property_id::text)
        || '/sessions/' || lower(target_session_id::text)
        || '/packages/' || lower(target_package_id::text)
        || '/pdfs/' || target_report_type || '.pdf';
$function$;

CREATE OR REPLACE FUNCTION public.report_package_file_matches_package(target_package_id uuid, target_org_id uuid, target_property_id uuid, target_session_id uuid, target_snapshot_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select exists (
        select 1
        from public.report_packages package_row
        where package_row.id = target_package_id
          and package_row.org_id = target_org_id
          and package_row.property_id = target_property_id
          and package_row.session_id = target_session_id
          and package_row.snapshot_id = target_snapshot_id
          and package_row.deleted_at is null
    );
$function$;

CREATE OR REPLACE FUNCTION public.temporary_export_expected_storage_path(target_org_id uuid, target_property_id uuid, target_session_id uuid, target_export_id uuid)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    select 'orgs/' || lower(target_org_id::text)
        || '/properties/' || lower(target_property_id::text)
        || '/sessions/' || lower(target_session_id::text)
        || '/exports/stamped-jpg/' || lower(target_export_id::text) || '.zip';
$function$;

alter table public.report_packages add constraint report_packages_attempt_count_check CHECK ((attempt_count >= 0));
alter table public.report_packages add constraint report_packages_generation_trigger_check CHECK ((generation_trigger = ANY (ARRAY['session_completed'::text, 'manual_retry'::text, 'regenerated'::text])));
alter table public.report_packages add constraint report_packages_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);
alter table public.report_packages add constraint report_packages_pkey PRIMARY KEY (id);
alter table public.report_packages add constraint report_packages_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id);
alter table public.report_packages add constraint report_packages_session_id_fkey FOREIGN KEY (session_id) REFERENCES sessions(id);
alter table public.report_packages add constraint report_packages_sha256_check CHECK ((((logo_asset_sha256 IS NULL) OR (logo_asset_sha256 ~ '^[0-9a-f]{64}$'::text)) AND ((raw_session_json_sha256 IS NULL) OR (raw_session_json_sha256 ~ '^[0-9a-f]{64}$'::text)) AND ((snapshot_payload_sha256 IS NULL) OR (snapshot_payload_sha256 ~ '^[0-9a-f]{64}$'::text)) AND ((report_input_sha256 IS NULL) OR (report_input_sha256 ~ '^[0-9a-f]{64}$'::text)) AND ((prepared_media_manifest_sha256 IS NULL) OR (prepared_media_manifest_sha256 ~ '^[0-9a-f]{64}$'::text)) AND ((report_plan_sha256 IS NULL) OR (report_plan_sha256 ~ '^[0-9a-f]{64}$'::text))));
alter table public.report_packages add constraint report_packages_snapshot_id_fkey FOREIGN KEY (snapshot_id) REFERENCES session_snapshots(id);
alter table public.report_packages add constraint report_packages_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'generating'::text, 'ready'::text, 'failed'::text, 'pruned'::text])));

alter table public.temporary_exports add constraint temporary_exports_artifact_type_check CHECK ((artifact_type = 'stamped_jpg_zip'::text));
alter table public.temporary_exports add constraint temporary_exports_attempt_count_check CHECK ((attempt_count >= 0));
alter table public.temporary_exports add constraint temporary_exports_mime_type_check CHECK ((mime_type = 'application/zip'::text));
alter table public.temporary_exports add constraint temporary_exports_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);
alter table public.temporary_exports add constraint temporary_exports_pkey PRIMARY KEY (id);
alter table public.temporary_exports add constraint temporary_exports_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id);
alter table public.temporary_exports add constraint temporary_exports_ready_payload_check CHECK (((status <> 'ready'::text) OR ((storage_path IS NOT NULL) AND (filename IS NOT NULL) AND (byte_size IS NOT NULL) AND (byte_size > 0) AND (sha256 IS NOT NULL) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND (expires_at IS NOT NULL))));
alter table public.temporary_exports add constraint temporary_exports_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES users_profile(id);
alter table public.temporary_exports add constraint temporary_exports_session_id_fkey FOREIGN KEY (session_id) REFERENCES sessions(id);
alter table public.temporary_exports add constraint temporary_exports_snapshot_id_fkey FOREIGN KEY (snapshot_id) REFERENCES session_snapshots(id);
alter table public.temporary_exports add constraint temporary_exports_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'generating'::text, 'ready'::text, 'failed'::text, 'expired'::text])));
alter table public.temporary_exports add constraint temporary_exports_storage_bucket_check CHECK ((storage_bucket = 'scoutcapture-deliverables'::text));
alter table public.temporary_exports add constraint temporary_exports_storage_path_check CHECK (((storage_path IS NULL) OR (storage_path = temporary_export_expected_storage_path(org_id, property_id, session_id, id))));

alter table public.report_package_files add constraint report_package_files_counts_check CHECK (((byte_size > 0) AND (page_count > 0)));
alter table public.report_package_files add constraint report_package_files_mime_type_check CHECK ((mime_type = 'application/pdf'::text));
alter table public.report_package_files add constraint report_package_files_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);
alter table public.report_package_files add constraint report_package_files_package_id_fkey FOREIGN KEY (package_id) REFERENCES report_packages(id);
alter table public.report_package_files add constraint report_package_files_pkey PRIMARY KEY (id);
alter table public.report_package_files add constraint report_package_files_property_id_fkey FOREIGN KEY (property_id) REFERENCES properties(id);
alter table public.report_package_files add constraint report_package_files_report_type_check CHECK ((report_type = ANY (ARRAY['property_report'::text, 'flagged_observations'::text, 'flagged_comparison'::text, 'punchlist_update'::text])));
alter table public.report_package_files add constraint report_package_files_session_id_fkey FOREIGN KEY (session_id) REFERENCES sessions(id);
alter table public.report_package_files add constraint report_package_files_sha256_check CHECK ((sha256 ~ '^[0-9a-f]{64}$'::text));
alter table public.report_package_files add constraint report_package_files_snapshot_id_fkey FOREIGN KEY (snapshot_id) REFERENCES session_snapshots(id);
alter table public.report_package_files add constraint report_package_files_storage_bucket_check CHECK ((storage_bucket = 'scoutcapture-deliverables'::text));
alter table public.report_package_files add constraint report_package_files_storage_path_check CHECK ((storage_path = report_package_file_expected_storage_path(org_id, property_id, session_id, package_id, report_type)));

CREATE UNIQUE INDEX idx_report_packages_idempotency_active ON public.report_packages USING btree (idempotency_key) WHERE (deleted_at IS NULL);
CREATE INDEX idx_report_packages_property_completed_active ON public.report_packages USING btree (property_id, session_completed_at DESC, completed_at DESC) WHERE (deleted_at IS NULL);
CREATE INDEX idx_report_packages_snapshot_active ON public.report_packages USING btree (snapshot_id) WHERE (deleted_at IS NULL);
CREATE INDEX idx_report_packages_status_active ON public.report_packages USING btree (status, updated_at) WHERE (deleted_at IS NULL);

alter table public.report_packages enable row level security;
revoke all on public.report_packages from anon, authenticated;
grant select on public.report_packages to authenticated;
grant select, insert, update, delete on public.report_packages to service_role;

create policy report_packages_select_property_access on public.report_packages for select to authenticated using (((deleted_at IS NULL) AND has_property_access(org_id, property_id)));

CREATE TRIGGER set_report_packages_updated_at BEFORE UPDATE ON public.report_packages FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_temporary_exports_expiry_ready ON public.temporary_exports USING btree (expires_at) WHERE ((deleted_at IS NULL) AND (status = 'ready'::text));
CREATE UNIQUE INDEX idx_temporary_exports_inflight_cache_active ON public.temporary_exports USING btree (cache_key) WHERE ((deleted_at IS NULL) AND (status = ANY (ARRAY['queued'::text, 'generating'::text])));
CREATE INDEX idx_temporary_exports_property_active ON public.temporary_exports USING btree (property_id, requested_at DESC) WHERE (deleted_at IS NULL);
CREATE INDEX idx_temporary_exports_status_active ON public.temporary_exports USING btree (status, updated_at) WHERE (deleted_at IS NULL);

alter table public.temporary_exports enable row level security;
revoke all on public.temporary_exports from anon, authenticated;
grant select on public.temporary_exports to authenticated;
grant select, insert, update, delete on public.temporary_exports to service_role;

create policy temporary_exports_select_property_access on public.temporary_exports for select to authenticated using (((deleted_at IS NULL) AND has_property_access(org_id, property_id)));

CREATE TRIGGER set_temporary_exports_updated_at BEFORE UPDATE ON public.temporary_exports FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE UNIQUE INDEX idx_report_package_files_package_type_active ON public.report_package_files USING btree (package_id, report_type) WHERE (deleted_at IS NULL);
CREATE INDEX idx_report_package_files_property_active ON public.report_package_files USING btree (property_id, created_at DESC) WHERE (deleted_at IS NULL);
CREATE UNIQUE INDEX idx_report_package_files_storage_active ON public.report_package_files USING btree (storage_bucket, storage_path) WHERE ((deleted_at IS NULL) AND (storage_deleted_at IS NULL));

alter table public.report_package_files enable row level security;
revoke all on public.report_package_files from anon, authenticated;
grant select on public.report_package_files to authenticated;
grant select, insert, update, delete on public.report_package_files to service_role;

create policy report_package_files_select_property_access on public.report_package_files for select to authenticated using (((deleted_at IS NULL) AND has_property_access(org_id, property_id)));

CREATE TRIGGER set_report_package_files_updated_at BEFORE UPDATE ON public.report_package_files FOR EACH ROW EXECUTE FUNCTION set_updated_at();

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('scoutcapture-deliverables','scoutcapture-deliverables',false,null,array['application/json', 'application/pdf', 'application/zip', 'image/heic', 'image/heif', 'image/jpeg', 'image/jpg', 'image/pjpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

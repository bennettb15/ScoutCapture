-- Storage policy parity from scout-dev catalog on 2026-11-27.
-- The existing repository migrations included buckets but omitted these access policies.

create policy deliverable_objects_delete_denied on storage.objects for delete to authenticated using (((bucket_id = 'scoutcapture-deliverables'::text) AND false));

create policy deliverable_objects_insert_denied on storage.objects for insert to authenticated with check (((bucket_id = 'scoutcapture-deliverables'::text) AND false));

create policy deliverable_objects_select_with_visible_row on storage.objects for select to authenticated using (((bucket_id = 'scoutcapture-deliverables'::text) AND ((EXISTS ( SELECT 1
   FROM (report_package_files file_row
     JOIN report_packages package_row ON ((package_row.id = file_row.package_id)))
  WHERE ((file_row.storage_bucket = objects.bucket_id) AND (file_row.storage_path = objects.name) AND (file_row.deleted_at IS NULL) AND (file_row.storage_deleted_at IS NULL) AND (package_row.deleted_at IS NULL) AND (package_row.status = 'ready'::text) AND has_property_access(file_row.org_id, file_row.property_id)))) OR (EXISTS ( SELECT 1
   FROM temporary_exports export_row
  WHERE ((export_row.storage_bucket = objects.bucket_id) AND (export_row.storage_path = objects.name) AND (export_row.deleted_at IS NULL) AND (export_row.status = 'ready'::text) AND (export_row.expires_at > timezone('utc'::text, now())) AND has_property_access(export_row.org_id, export_row.property_id)))))));

create policy deliverable_objects_update_denied on storage.objects for update to authenticated using (((bucket_id = 'scoutcapture-deliverables'::text) AND false)) with check (((bucket_id = 'scoutcapture-deliverables'::text) AND false));

create policy scoutcapture_originals_authenticated_insert on storage.objects for insert to authenticated with check ((bucket_id = 'scoutcapture-originals'::text));

create policy scoutcapture_originals_authenticated_select on storage.objects for select to authenticated using ((bucket_id = 'scoutcapture-originals'::text));

create policy scoutcapture_originals_authenticated_update on storage.objects for update to authenticated using ((bucket_id = 'scoutcapture-originals'::text)) with check ((bucket_id = 'scoutcapture-originals'::text));

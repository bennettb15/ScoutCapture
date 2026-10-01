-- One-time Test Org cleanup. Exact 53-ID allowlist from the 2026-10-01
-- read-only inventory. Run after the two retention migrations.
-- This function only deletes after Storage objects have been removed by the
-- scoped worker. Run test_org_one_time_purge_teardown.sql afterward.
create or replace function public.finalize_approved_test_org_property_purge(
    target_property_id uuid,
    dry_run boolean default true
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    target_org_id uuid;
    target_deleted_at timestamptz;
    target_is_archived boolean;
    expected_deleted_at timestamptz;
begin
    if auth.role() is distinct from 'service_role' then
        raise exception 'Service role required.' using errcode = '42501';
    end if;

    select approved.deleted_at into expected_deleted_at
    from (values
        ('00bcc766-6e09-46f2-abc1-75565e7c9257'::uuid, '2026-09-22 10:48:20.93611+00'::timestamptz),
        ('07ccbcd6-2d2d-459f-8352-9f6da0249c75'::uuid, '2026-09-01 19:27:18.975583+00'::timestamptz),
        ('10c272bd-1685-43e3-a2bd-5bf6c11efb73'::uuid, '2026-09-22 13:33:30.268492+00'::timestamptz),
        ('1596ca7c-3133-40c9-86eb-b1f95cb681c4'::uuid, '2026-08-19 20:10:03.740949+00'::timestamptz),
        ('1ff0eb11-5d02-4d5e-a552-1a11dee26439'::uuid, '2026-09-19 17:00:12.244989+00'::timestamptz),
        ('210289ee-cbcc-4058-af77-cb4bcec2d677'::uuid, '2026-08-19 20:07:30.684608+00'::timestamptz),
        ('243a9328-066d-442d-a4f5-2abbd1e2857b'::uuid, '2026-08-14 15:16:48.607757+00'::timestamptz),
        ('2732b6d7-4ad8-4b3a-9cf1-4de5290cc1e8'::uuid, '2026-06-15 13:07:39.91279+00'::timestamptz),
        ('27b8e1b5-5700-4353-938c-ef785d2fbc26'::uuid, '2026-09-01 20:45:21.330563+00'::timestamptz),
        ('2c95067d-7e8f-4070-abc4-c20c8888e33c'::uuid, '2026-09-21 15:04:42.621342+00'::timestamptz),
        ('35689031-0529-4742-b3d6-c5a2ab11ac21'::uuid, '2026-09-21 15:17:14.677409+00'::timestamptz),
        ('41b47578-7bae-4618-9a45-79ec5521a2c1'::uuid, '2026-09-22 04:02:21.278451+00'::timestamptz),
        ('438ed2da-3505-4d3c-863c-b694db82a869'::uuid, '2026-09-22 02:46:27.478973+00'::timestamptz),
        ('4aec0247-191d-4e5f-a0eb-d4fcb01b33c8'::uuid, '2026-09-22 02:21:53.644049+00'::timestamptz),
        ('4bd3c325-7b3b-4d00-bace-3ef747c98244'::uuid, '2026-09-21 15:04:36.150502+00'::timestamptz),
        ('534e32af-0823-43b0-adb1-771338ddec3b'::uuid, '2026-09-20 16:40:13.942151+00'::timestamptz),
        ('5b4a0d29-c866-4790-8f40-c31b4878ec3d'::uuid, '2026-09-22 02:22:08.845156+00'::timestamptz),
        ('5e0f5307-8b9d-4cd3-a07f-280a300570fb'::uuid, '2026-08-14 15:16:32.476223+00'::timestamptz),
        ('69cc2fa7-7fa3-465b-a320-09107a29b16d'::uuid, '2026-08-19 20:01:41.122754+00'::timestamptz),
        ('6e0165d5-3e3a-43cc-b709-a45ce11e8b9a'::uuid, '2026-09-21 15:04:30.156269+00'::timestamptz),
        ('7248ceeb-5f2b-4f75-a0d8-f9526ec9cde1'::uuid, '2026-09-22 03:49:56.565696+00'::timestamptz),
        ('77c8b4ad-1e2c-4465-98a2-1c3a118f4b10'::uuid, '2026-08-19 20:06:59.100993+00'::timestamptz),
        ('7a8b3034-7245-410c-9fce-06b731f8a432'::uuid, '2026-09-20 22:48:20.750078+00'::timestamptz),
        ('7e105ce7-88e6-47b4-a69a-0d1e4659122e'::uuid, '2026-08-14 15:16:45.49941+00'::timestamptz),
        ('856a1c26-bc30-448d-b830-05af83b4e468'::uuid, '2026-09-01 12:33:02.775762+00'::timestamptz),
        ('87c17671-ffec-4c12-91d3-a1e90bc82619'::uuid, '2026-09-22 03:36:20.341169+00'::timestamptz),
        ('91d46f11-08e7-45a9-b16d-9fe183e4a580'::uuid, '2026-09-22 03:56:47.498433+00'::timestamptz),
        ('93d2879a-f9c8-437a-96f1-cc60831db534'::uuid, '2026-09-22 02:40:58.758828+00'::timestamptz),
        ('9dbd7f1e-69b0-4da7-becd-105b01fb6983'::uuid, '2026-09-05 02:19:29.844144+00'::timestamptz),
        ('a65795b9-8846-42a7-b7f7-c54b0d39ddce'::uuid, '2026-09-21 15:34:51.647956+00'::timestamptz),
        ('b06fea72-f4cf-4dba-8abf-3ebedbbcef51'::uuid, '2026-08-19 20:00:13.375874+00'::timestamptz),
        ('b082bcd2-5bbc-4630-bcf9-1101289ec8a0'::uuid, '2026-09-20 22:48:26.524667+00'::timestamptz),
        ('b0a045ba-3182-4a55-8e22-e22eb30aa370'::uuid, '2026-08-14 15:16:35.981896+00'::timestamptz),
        ('b2d9da27-4b6e-445e-b6af-b708fe268393'::uuid, '2026-09-04 22:46:00.818159+00'::timestamptz),
        ('b7b435bb-786d-4477-88a9-f83003c0dd5d'::uuid, '2026-09-20 00:54:53.325986+00'::timestamptz),
        ('bd0f368c-434e-449e-827d-2e9ea1eb51d8'::uuid, '2026-09-20 16:39:58.172065+00'::timestamptz),
        ('c0c8eab8-a1e8-4e76-8864-cef01159f03c'::uuid, '2026-09-01 17:32:15.431901+00'::timestamptz),
        ('c7741153-f63c-417d-b758-6de52bd62be3'::uuid, '2026-09-01 12:32:58.69382+00'::timestamptz),
        ('c86f55ba-305a-4c99-942e-0dec0fd8286c'::uuid, '2026-09-22 04:06:31.334566+00'::timestamptz),
        ('cf12486f-a5bb-4306-9c09-9064bbe00ab5'::uuid, '2026-08-19 20:00:09.316658+00'::timestamptz),
        ('d169ef0a-00ef-4fac-8779-3a49b424aad2'::uuid, '2026-09-05 02:53:37.527845+00'::timestamptz),
        ('d2913da4-9f69-498e-a5a0-3fa2f319c91b'::uuid, '2026-08-20 00:29:35.542027+00'::timestamptz),
        ('d626703e-671b-44e1-a26d-642c5597730e'::uuid, '2026-09-03 19:14:33.226659+00'::timestamptz),
        ('dbbb2215-d6a5-4050-b5e6-ce45a5cfbf59'::uuid, '2026-09-22 02:22:01.93172+00'::timestamptz),
        ('dc9adf2a-585f-4727-9938-f1bdebfc0399'::uuid, '2026-09-04 22:46:04.973732+00'::timestamptz),
        ('dd564834-bf66-429f-91ae-b6bc55d27adc'::uuid, '2026-09-23 13:55:07.734114+00'::timestamptz),
        ('e1c764d1-1685-4ead-baf1-59e0bf2d6678'::uuid, '2026-09-21 15:04:49.976776+00'::timestamptz),
        ('e7b6d60f-30e9-422b-be9e-dc3f95182b6e'::uuid, '2026-09-20 16:40:07.88427+00'::timestamptz),
        ('ea026e86-a60d-468c-b4c4-91930b138269'::uuid, '2026-08-14 15:16:56.003874+00'::timestamptz),
        ('ed850b0e-2fe8-4b3c-8778-138f4ccd0030'::uuid, '2026-09-20 16:40:02.855204+00'::timestamptz),
        ('f89e5a4a-c16a-4d1b-be89-27095c981585'::uuid, '2026-09-22 10:48:16.546975+00'::timestamptz),
        ('faf6d3cb-4d2e-42c6-9c13-3a1a9d99fe50'::uuid, '2026-09-22 10:48:12.058491+00'::timestamptz),
        ('fd46551f-566e-49cf-9cfa-7049405f486f'::uuid, '2026-09-05 02:19:26.817446+00'::timestamptz)
    ) as approved(id, deleted_at)
    where approved.id = target_property_id;
    if not found then
        raise exception 'Property ID was not in the reviewed Test Org list.' using errcode = '42501';
    end if;

    select org_id, deleted_at, is_archived
    into target_org_id, target_deleted_at, target_is_archived
    from public.properties
    where id = target_property_id
    for update;
    if not found then
        return false;
    end if;
    if target_org_id <> 'd4ba94ff-25e1-4072-aa79-9a548fcb3008'::uuid
       or target_deleted_at is null
       or target_deleted_at is distinct from expected_deleted_at
       or target_is_archived then
        raise exception 'Property no longer matches the approved deleted Test Org inventory.' using errcode = 'P0001';
    end if;
    if public.property_has_active_occupancy(target_property_id) then
        raise exception 'Property has active occupancy.' using errcode = 'P0001';
    end if;
    if dry_run then
        return false;
    end if;

    if to_regclass('public.punchlist_activity') is not null then
        execute 'delete from public.punchlist_activity where property_id = $1'
        using target_property_id;
    end if;
    delete from public.observation_updates where property_id = target_property_id;
    delete from public.observations where property_id = target_property_id;
    if to_regclass('public.report_package_email_notifications') is not null then
        execute 'delete from public.report_package_email_notifications where property_id = $1'
        using target_property_id;
    end if;
    delete from public.report_package_files where property_id = target_property_id;
    delete from public.report_packages where property_id = target_property_id;
    delete from public.temporary_exports where property_id = target_property_id;
    update public.session_snapshots
    set supersedes_snapshot_id = null,
        superseded_by_snapshot_id = null
    where property_id = target_property_id;
    delete from public.session_snapshots where property_id = target_property_id;
    delete from public.shots where property_id = target_property_id;
    delete from public.session_events where property_id = target_property_id;
    delete from public.sessions where property_id = target_property_id;
    if to_regclass('public.portal_invite_property_grants') is not null then
        execute 'delete from public.portal_invite_property_grants where property_id = $1'
        using target_property_id;
    end if;
    delete from public.property_access_grants where property_id = target_property_id;
    delete from public.properties where id = target_property_id;
    return true;
end;
$$;

revoke all on function public.finalize_approved_test_org_property_purge(uuid, boolean)
    from public, anon, authenticated;
grant execute on function public.finalize_approved_test_org_property_purge(uuid, boolean)
    to service_role;

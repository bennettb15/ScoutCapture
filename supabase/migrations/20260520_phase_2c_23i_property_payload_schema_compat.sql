-- Phase 2C-23I local/dev compatibility:
-- Keep the public.properties table aligned with the app's current property
-- payload/read shape. These columns are nullable and additive so existing
-- local/dev rows remain valid.

alter table public.properties
    add column if not exists folder_id text,
    add column if not exists client_name text,
    add column if not exists client_email text,
    add column if not exists client_phone text,
    add column if not exists baseline_session_id uuid;

comment on column public.properties.folder_id is
    'Optional local folder identifier carried for compatibility with ScoutCapture property metadata reads.';

comment on column public.properties.client_name is
    'Optional client contact name shadow-written by ScoutCapture property payloads.';

comment on column public.properties.client_email is
    'Optional client contact email shadow-written by ScoutCapture property payloads.';

comment on column public.properties.client_phone is
    'Optional client contact phone shadow-written by ScoutCapture property payloads.';

comment on column public.properties.baseline_session_id is
    'Optional baseline session identifier used by ScoutCapture property metadata reads.';

notify pgrst, 'reload schema';

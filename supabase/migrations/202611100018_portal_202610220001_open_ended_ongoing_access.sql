-- Source: scout-site@ef46714:supabase/migrations/202610220001_open_ended_ongoing_access.sql
-- Imported for the isolated ScoutCapture 2.0 backend baseline.
-- A paid subscription can renew monthly without a preset access cutoff.
-- Setting an end date later schedules access revocation at that date.
alter table public.customer_lifecycle
    drop constraint if exists customer_lifecycle_ongoing_pair;

alter table public.customer_lifecycle
    add constraint customer_lifecycle_ongoing_pair check (
        (ongoing_started_at is null and ongoing_expires_at is null)
        or (
            ongoing_started_at is not null
            and (ongoing_expires_at is null or ongoing_expires_at > ongoing_started_at)
        )
    );

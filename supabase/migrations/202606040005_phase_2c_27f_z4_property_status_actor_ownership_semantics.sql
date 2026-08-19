-- Phase 2C-27F-Z4 follow-up
-- Property status ownership is user-or-device based. A same authenticated user
-- remains the owner even when a legacy/rebuilt row carries an older device id.

create or replace function public.property_status_actor_owns(
    target_owner_user_id uuid,
    target_owner_device_id text,
    target_device_id text
)
returns boolean
language sql
stable
as $$
    select (
        target_owner_user_id is not null
        and target_owner_user_id = auth.uid()
    )
    or (
        nullif(btrim(coalesce(target_owner_device_id, '')), '') is not null
        and nullif(btrim(coalesce(target_device_id, '')), '') is not null
        and btrim(target_owner_device_id) = btrim(target_device_id)
    );
$$;

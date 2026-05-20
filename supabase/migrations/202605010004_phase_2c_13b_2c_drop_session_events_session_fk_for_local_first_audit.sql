alter table public.session_events
    drop constraint if exists session_events_session_id_fkey;

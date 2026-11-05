-- Progress belongs to the background request so it survives browser navigation.
alter table public.on_demand_report_requests
    add column progress_step text not null default 'queued'
    check (progress_step in ('queued','validating','preparing_photos','rendering','uploading','ready','failed'));

update public.on_demand_report_requests
set progress_step = case when status in ('ready','failed') then status
                         when status = 'generating' then 'preparing_photos' else 'queued' end;

-- Existing live tenant downloads previously expired one hour after completion.
-- Extend only those still available; expired outputs are never revived.
update public.on_demand_report_requests
set expires_at = expires_at + interval '23 hours'
where kind = 'tenant_comparison' and status = 'ready' and expires_at > now();

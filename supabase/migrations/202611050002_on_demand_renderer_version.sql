-- Keep temporary downloads from an older layout out of new generation requests.
alter table public.on_demand_report_requests
    add column renderer_version text not null default 'legacy';

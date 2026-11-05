-- On-demand PDFs are temporary downloads, never report-package artifacts.
create table public.on_demand_report_requests (
    id uuid primary key default gen_random_uuid(),
    org_id uuid not null,
    property_id uuid not null,
    requested_by uuid not null,
    kind text not null default 'tenant_comparison' check (kind in ('tenant_comparison','punchlist_all')),
    before_package_id uuid,
    after_package_id uuid,
    status text not null default 'queued' check (status in ('queued','generating','ready','failed','expired')),
    requested_at timestamptz not null default now(),
    locked_at timestamptz,
    expires_at timestamptz not null default (now() + interval '1 day'),
    storage_path text,
    filename text,
    last_error text,
    check ((kind = 'tenant_comparison' and before_package_id is not null and after_package_id is not null and before_package_id <> after_package_id) or
           (kind = 'punchlist_all' and before_package_id is null and after_package_id is null))
);
create index on_demand_report_requests_queue on public.on_demand_report_requests(status, requested_at);
create index on_demand_report_requests_expiry on public.on_demand_report_requests(expires_at);
alter table public.on_demand_report_requests enable row level security;
revoke all on public.on_demand_report_requests from public, anon, authenticated;
grant all on public.on_demand_report_requests to service_role;

create function public.validate_tenant_comparison_scope() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if new.kind = 'punchlist_all' then
        if not exists (select 1 from public.properties where id = new.property_id and org_id = new.org_id and deleted_at is null) then
            raise exception 'Invalid property scope';
        end if;
        return new;
    end if;
    if not exists (
        select 1 from public.report_packages b, public.report_packages a, public.properties p
        where b.id = new.before_package_id and a.id = new.after_package_id
          and b.org_id = new.org_id and a.org_id = new.org_id
          and b.property_id = new.property_id and a.property_id = new.property_id
          and p.id = new.property_id and p.org_id = new.org_id and p.deleted_at is null
          and b.status = 'ready' and a.status = 'ready'
          and b.deleted_at is null and a.deleted_at is null
    ) then raise exception 'Invalid tenant comparison scope'; end if;
    return new;
end;
$$;
revoke all on function public.validate_tenant_comparison_scope() from public, anon, authenticated;
create trigger validate_tenant_comparison_scope before insert or update of
    org_id, property_id, kind, before_package_id, after_package_id
    on public.on_demand_report_requests for each row execute function public.validate_tenant_comparison_scope();

insert into storage.buckets(id, name, public) values ('scoutcapture-on-demand','scoutcapture-on-demand',false)
on conflict (id) do nothing;

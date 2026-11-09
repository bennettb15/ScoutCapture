-- One optional report logo per organization. Only trusted server and worker code
-- reads this table or its private storage bucket.
create table if not exists public.org_report_branding (
  org_id uuid primary key references public.orgs(id) on delete cascade,
  logo_path text not null,
  updated_by uuid references public.users_profile(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint org_report_branding_logo_path_scope
    check (logo_path like 'orgs/' || org_id::text || '/logos/%.png')
);

alter table public.org_report_branding enable row level security;
revoke all on public.org_report_branding from public, anon, authenticated;
grant select, insert, update, delete on public.org_report_branding to service_role;

drop trigger if exists org_report_branding_set_updated_at on public.org_report_branding;
create trigger org_report_branding_set_updated_at
  before update on public.org_report_branding
  for each row execute function public.set_updated_at();

insert into storage.buckets (id, name, public)
values ('scoutcapture-org-branding', 'scoutcapture-org-branding', false)
on conflict (id) do nothing;

comment on table public.org_report_branding is
  'Optional private report logo for newly generated PDFs from one organization.';

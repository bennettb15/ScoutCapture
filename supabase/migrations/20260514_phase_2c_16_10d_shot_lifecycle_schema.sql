alter table public.shots
    add column if not exists lifecycle_state text,
    add column if not exists retired_at timestamptz,
    add column if not exists retired_reason text,
    add column if not exists retired_by uuid,
    add column if not exists superseded_by_shot_id uuid,
    add column if not exists supersedes_shot_id uuid,
    add column if not exists replacement_reason text,
    add column if not exists hidden_from_reports boolean,
    add column if not exists hidden_from_gallery boolean,
    add column if not exists lifecycle_updated_at timestamptz;

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'shots_lifecycle_state_check'
          and conrelid = 'public.shots'::regclass
    ) then
        alter table public.shots
            add constraint shots_lifecycle_state_check
            check (
                lifecycle_state is null
                or lifecycle_state in ('active', 'retired', 'superseded')
            );
    end if;
end;
$$;

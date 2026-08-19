begin;

create or replace function public.test_assert(condition boolean, message text)
returns void
language plpgsql
as $$
begin
    if not condition then
        raise exception '%', message;
    end if;
end;
$$;

select public.test_assert(
    exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'shots'
          and column_name = 'lifecycle_state'
          and is_nullable = 'YES'
    ),
    'shots.lifecycle_state should exist and be nullable'
);

select public.test_assert(
    exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'shots'
          and column_name = 'retired_at'
          and data_type = 'timestamp with time zone'
          and is_nullable = 'YES'
    ),
    'shots.retired_at should exist as nullable timestamptz'
);

select public.test_assert(
    exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'shots'
          and column_name in (
              'retired_reason',
              'retired_by',
              'superseded_by_shot_id',
              'supersedes_shot_id',
              'replacement_reason',
              'hidden_from_reports',
              'hidden_from_gallery',
              'lifecycle_updated_at'
          )
        group by table_schema, table_name
        having count(*) = 8
    ),
    'shots lifecycle metadata columns should exist'
);

select public.test_assert(
    exists (
        select 1
        from pg_constraint
        where conrelid = 'public.shots'::regclass
          and conname = 'shots_lifecycle_state_check'
          and pg_get_constraintdef(oid) like '%lifecycle_state IS NULL%'
          and pg_get_constraintdef(oid) like '%active%'
          and pg_get_constraintdef(oid) like '%retired%'
          and pg_get_constraintdef(oid) like '%superseded%'
    ),
    'shots lifecycle check should allow null active retired superseded'
);

rollback;

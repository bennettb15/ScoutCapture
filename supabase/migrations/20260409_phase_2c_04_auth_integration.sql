create or replace function public.handle_auth_user_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.users_profile (
        id,
        email,
        full_name,
        updated_by
    )
    values (
        new.id,
        new.email,
        coalesce(
            nullif(new.raw_user_meta_data ->> 'full_name', ''),
            nullif(new.raw_user_meta_data ->> 'name', '')
        ),
        new.id
    )
    on conflict (id) do update
    set email = coalesce(excluded.email, public.users_profile.email),
        full_name = coalesce(excluded.full_name, public.users_profile.full_name),
        updated_by = excluded.updated_by,
        deleted_at = null;

    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
    after insert on auth.users
    for each row
    execute function public.handle_auth_user_created();

create or replace function public.ensure_current_user_profile()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    current_user_id uuid := auth.uid();
    current_email text := nullif(auth.jwt() ->> 'email', '');
    current_full_name text := coalesce(
        nullif(auth.jwt() -> 'user_metadata' ->> 'full_name', ''),
        nullif(auth.jwt() -> 'user_metadata' ->> 'name', '')
    );
begin
    if current_user_id is null then
        raise exception 'Authenticated user required';
    end if;

    insert into public.users_profile (
        id,
        email,
        full_name,
        updated_by
    )
    values (
        current_user_id,
        current_email,
        current_full_name,
        current_user_id
    )
    on conflict (id) do update
    set email = coalesce(excluded.email, public.users_profile.email),
        full_name = coalesce(excluded.full_name, public.users_profile.full_name),
        updated_by = excluded.updated_by,
        deleted_at = null;

    return current_user_id;
end;
$$;

grant execute on function public.ensure_current_user_profile() to authenticated;

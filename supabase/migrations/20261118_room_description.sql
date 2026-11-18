-- Evansen Co Living PMS — short room description (max 30 characters)
-- Run once in Supabase SQL Editor. Safe to re-run.

alter table public.rooms add column if not exists description text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'rooms_description_max_30') then
    alter table public.rooms
      add constraint rooms_description_max_30 check (description is null or char_length(description) <= 30);
  end if;
end $$;

select name, description from public.rooms order by created_at;

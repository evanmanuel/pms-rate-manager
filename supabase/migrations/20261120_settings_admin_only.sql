-- Evansen Co Living PMS — Settings are administrator-only.
-- Staff can still READ rooms and channels (needed for bookings); only the administrator can add, rename or remove them.
-- Run once in Supabase SQL Editor. Safe to re-run.

do $$
declare t text;
begin
  foreach t in array array['rooms', 'channels'] loop
    execute format('drop policy if exists "Signed-in users full access" on public.%I', t);
    execute format('drop policy if exists "Signed-in users can read" on public.%I', t);
    execute format('drop policy if exists "Admin can change" on public.%I', t);
    execute format('create policy "Signed-in users can read" on public.%I for select to authenticated using (true)', t);
    execute format($p$create policy "Admin can change" on public.%I for all to authenticated
                     using ((auth.jwt() ->> 'email') = 'evansen.coliving@gmail.com')
                     with check ((auth.jwt() ->> 'email') = 'evansen.coliving@gmail.com')$p$, t);
  end loop;
end $$;

select tablename, policyname, cmd from pg_policies where schemaname = 'public' and tablename in ('rooms', 'channels') order by 1, 2;

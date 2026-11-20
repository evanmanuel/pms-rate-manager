-- Evansen Co Living PMS — To Do list: items dismissed by staff (shared by everyone).
-- Each To Do item has a key built from the booking and the relevant dates/amounts, so a dismissed item
-- comes back by itself if that booking changes. Run once in Supabase SQL Editor. Safe to re-run.

create table if not exists public.todo_dismissals (
  key          text primary key,
  label        text,
  dismissed_by text default (auth.jwt() ->> 'email'),
  dismissed_at timestamptz not null default now()
);
alter table public.todo_dismissals enable row level security;
drop policy if exists "Signed-in users can read dismissals" on public.todo_dismissals;
create policy "Signed-in users can read dismissals" on public.todo_dismissals for select to authenticated using (true);
drop policy if exists "Signed-in users can dismiss" on public.todo_dismissals;
create policy "Signed-in users can dismiss" on public.todo_dismissals for insert to authenticated with check (true);
drop policy if exists "Signed-in users can restore" on public.todo_dismissals;
create policy "Signed-in users can restore" on public.todo_dismissals for delete to authenticated using (true);

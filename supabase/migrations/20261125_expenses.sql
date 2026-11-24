-- Evansen Co Living PMS — property expenses (Electricity / Misc) for the Finance Report.
create table if not exists public.expenses (
  id          uuid primary key default gen_random_uuid(),
  spent_on    date not null default ((now() at time zone 'Asia/Makassar')::date),
  kind        text not null check (kind in ('Electricity', 'Misc')),
  amount      numeric not null check (amount > 0),
  method      text not null check (method in ('Cash', 'Bank Transfer', 'QRIS')),
  notes       text not null check (length(btrim(notes)) > 0),
  created_by  text default (auth.jwt() ->> 'email'),
  created_at  timestamptz not null default now()
);
create index if not exists expenses_spent_on_idx on public.expenses (spent_on);
alter table public.expenses enable row level security;
drop policy if exists "Signed-in users can read expenses" on public.expenses;
create policy "Signed-in users can read expenses" on public.expenses for select to authenticated using (true);
drop policy if exists "Signed-in users can add expenses" on public.expenses;
create policy "Signed-in users can add expenses" on public.expenses for insert to authenticated with check (true);
drop policy if exists "Signed-in users can remove expenses" on public.expenses;
create policy "Signed-in users can remove expenses" on public.expenses for delete to authenticated using (true);
select 'expenses ready' as status;

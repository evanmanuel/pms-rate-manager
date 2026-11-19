-- App-wide settings (e.g. bank details printed on invoices).
-- Everyone signed in can read; only the administrator can change them.
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by text
);

alter table public.app_settings enable row level security;

drop policy if exists "Signed-in users can read settings" on public.app_settings;
create policy "Signed-in users can read settings" on public.app_settings
  for select to authenticated using (true);

drop policy if exists "Admin can insert settings" on public.app_settings;
create policy "Admin can insert settings" on public.app_settings
  for insert to authenticated with check ((auth.jwt() ->> 'email') = 'evansen.coliving@gmail.com');

drop policy if exists "Admin can update settings" on public.app_settings;
create policy "Admin can update settings" on public.app_settings
  for update to authenticated
  using ((auth.jwt() ->> 'email') = 'evansen.coliving@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'evansen.coliving@gmail.com');

insert into public.app_settings (key, value)
values ('bank', '{"bank_name":"Bank Mandiri","account_name":"","account_number":"","swift":""}'::jsonb)
on conflict (key) do nothing;

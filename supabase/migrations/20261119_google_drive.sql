-- Evansen Co Living PMS — Google account connection + booking documents on Google Drive
-- Run once in Supabase SQL Editor. Safe to re-run.

-- 1) The connected Google account (one row). Only the server function can read it:
--    RLS is on and there are NO policies, so the website can never see the token.
create table if not exists public.google_connection (
  id             int primary key default 1 check (id = 1),
  email          text,
  refresh_token  text,
  scopes         text,
  root_folder_id text,
  connected_at   timestamptz,
  connected_by   text
);
alter table public.google_connection enable row level security;

-- 2) Drive folder for each booking ("<confirmation> - <guest name>")
create table if not exists public.reservation_drive_folders (
  reservation_id uuid primary key references public.reservations(id) on delete cascade,
  folder_id      text not null,
  created_at     timestamptz not null default now()
);
alter table public.reservation_drive_folders enable row level security;

-- 3) Files uploaded to a booking (the file itself lives in Google Drive)
create table if not exists public.reservation_files (
  id             uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  drive_file_id  text not null,
  name           text not null,
  mime_type      text,
  size_bytes     bigint,
  category       text not null default 'Other' check (category in ('Passport', 'Payment slip', 'Other')),
  uploaded_by    text,
  uploaded_at    timestamptz not null default now()
);
create index if not exists reservation_files_res_idx on public.reservation_files (reservation_id, uploaded_at desc);
alter table public.reservation_files enable row level security;
drop policy if exists "Signed-in users can read files" on public.reservation_files;
create policy "Signed-in users can read files" on public.reservation_files
  for select to authenticated using (true);
-- Inserts / deletes happen only through the server function.

select 'ok' as status;

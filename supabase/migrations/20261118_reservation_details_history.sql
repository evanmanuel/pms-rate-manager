-- Evansen Co Living PMS — reservation details, statuses and change history
-- Run once in Supabase SQL Editor. Safe to re-run.

-- 1) New reservation fields
alter table public.reservations
  add column if not exists guest_email    text,
  add column if not exists guest_phone    text,
  add column if not exists guests         integer default 1,
  add column if not exists notes          text,
  add column if not exists payment_status text default 'Unpaid',
  add column if not exists updated_at     timestamptz,
  add column if not exists updated_by     text;

-- 2) History log table (written only by the database trigger below)
create table if not exists public.reservation_history (
  id             bigint generated always as identity primary key,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  changed_at     timestamptz not null default now(),
  changed_by     text,
  action         text not null,          -- Created / Edited / Status changed / Cancelled
  changes        jsonb                   -- { field: { "old": ..., "new": ... } }
);
create index if not exists reservation_history_res_idx
  on public.reservation_history (reservation_id, changed_at desc);

alter table public.reservation_history enable row level security;
drop policy if exists "Signed-in users can read history" on public.reservation_history;
create policy "Signed-in users can read history" on public.reservation_history
  for select to authenticated using (true);
-- No insert/update/delete policies: users cannot write or alter the log directly.

-- 3) Rules before every change: lock cancelled bookings, stamp who/when
create or replace function public.reservation_before_update() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.status = 'Cancelled' then
    -- A cancelled booking is final. Only internal notes may still be added.
    if (to_jsonb(new) - 'notes' - 'updated_at' - 'updated_by')
       is distinct from (to_jsonb(old) - 'notes' - 'updated_at' - 'updated_by') then
      raise exception 'This reservation is cancelled and can no longer be changed. Please create a new booking.';
    end if;
  end if;
  if new.confirmation_number is distinct from old.confirmation_number then
    raise exception 'The confirmation number cannot be changed.';
  end if;
  new.updated_at := now();
  new.updated_by := coalesce(auth.jwt() ->> 'email', 'system');
  return new;
end $$;

drop trigger if exists reservation_before_update on public.reservations;
create trigger reservation_before_update
  before update on public.reservations
  for each row execute function public.reservation_before_update();

-- 4) Write the history log after every create / change
create or replace function public.reservation_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who     text  := coalesce(auth.jwt() ->> 'email', 'system');
  diff    jsonb := '{}'::jsonb;
  k       text;
  tracked text[] := array['guest_name','country','guest_email','guest_phone','guests',
                          'arrival_date','departure_date','room_name','rate','channel',
                          'status','payment_status','notes','room_night','room_revenue'];
  act     text;
begin
  if tg_op = 'INSERT' then
    insert into reservation_history (reservation_id, changed_by, action)
    values (new.id, who, 'Created');
    return new;
  end if;

  foreach k in array tracked loop
    if (to_jsonb(old) -> k) is distinct from (to_jsonb(new) -> k) then
      diff := diff || jsonb_build_object(k, jsonb_build_object('old', to_jsonb(old) -> k, 'new', to_jsonb(new) -> k));
    end if;
  end loop;
  if diff = '{}'::jsonb then return new; end if;

  act := case
           when new.status = 'Cancelled' and old.status is distinct from 'Cancelled' then 'Cancelled'
           when diff ? 'status' and (diff - 'status') = '{}'::jsonb then 'Status changed'
           else 'Edited'
         end;

  insert into reservation_history (reservation_id, changed_by, action, changes)
  values (new.id, who, act, diff);
  return new;
end $$;

drop trigger if exists reservation_log_change on public.reservations;
create trigger reservation_log_change
  after insert or update on public.reservations
  for each row execute function public.reservation_log_change();

-- 5) Check
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'reservations'
  and column_name in ('guest_email','guest_phone','guests','notes','payment_status','updated_at','updated_by')
order by column_name;

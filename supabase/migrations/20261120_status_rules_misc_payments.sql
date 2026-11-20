-- Evansen Co Living PMS — reservation status rules + Misc Payments.
-- Run once in Supabase SQL Editor. Safe to re-run.

-- 1) A stay is at least 1 night: departure must be after arrival
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'reservations_min_one_night') then
    alter table public.reservations add constraint reservations_min_one_night check (departure_date > arrival_date);
  end if;
end $$;

-- 2) Automatic No Show: guests who have not checked in by the day after arrival (Bali time).
--    Called once a day by the GitHub schedule (and safe to call any time). Logged in history as "system".
create or replace function public.mark_no_shows() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update reservations set status = 'No-show'
  where status = 'New Reservation'
    and arrival_date < (now() at time zone 'Asia/Makassar')::date;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.mark_no_shows() from public;
grant execute on function public.mark_no_shows() to anon, authenticated;

-- 3) Misc Payments: money actually collected outside the room payment (e.g. cancellation / no-show charge)
create table if not exists public.reservation_misc_payments (
  id             uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  paid_on        date not null default ((now() at time zone 'Asia/Makassar')::date),
  amount         numeric not null check (amount > 0),
  notes          text not null check (length(btrim(notes)) > 0),
  created_by     text default (auth.jwt() ->> 'email'),
  created_at     timestamptz not null default now()
);
create index if not exists reservation_misc_payments_res_idx on public.reservation_misc_payments (reservation_id);
alter table public.reservation_misc_payments enable row level security;
drop policy if exists "Signed-in users can read misc payments" on public.reservation_misc_payments;
create policy "Signed-in users can read misc payments" on public.reservation_misc_payments for select to authenticated using (true);
drop policy if exists "Signed-in users can add misc payments" on public.reservation_misc_payments;
create policy "Signed-in users can add misc payments" on public.reservation_misc_payments for insert to authenticated with check (true);
drop policy if exists "Signed-in users can remove misc payments" on public.reservation_misc_payments;
create policy "Signed-in users can remove misc payments" on public.reservation_misc_payments for delete to authenticated using (true);

-- History log for misc payments
create or replace function public.misc_payment_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who text := coalesce(auth.jwt() ->> 'email', 'system');
  r   public.reservation_misc_payments;
  txt text;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  txt := 'IDR ' || replace(to_char(r.amount, 'FM999,999,999,999'), ',', '.') || ' · ' || to_char(r.paid_on, 'DD Mon YYYY') || ' · ' || r.notes;
  insert into reservation_history (reservation_id, changed_by, action, changes)
  values (r.reservation_id, who,
          case when tg_op = 'DELETE' then 'Misc payment removed' else 'Misc payment added' end,
          jsonb_build_object('misc_payment', jsonb_build_object(
            'old', case when tg_op = 'DELETE' then to_jsonb(txt) else null end,
            'new', case when tg_op = 'DELETE' then null else to_jsonb(txt) end)));
  return null;
end $$;
drop trigger if exists misc_payment_log on public.reservation_misc_payments;
create trigger misc_payment_log after insert or delete on public.reservation_misc_payments
  for each row execute function public.misc_payment_log();

-- Run the No Show check once now
select public.mark_no_shows() as marked_no_show;

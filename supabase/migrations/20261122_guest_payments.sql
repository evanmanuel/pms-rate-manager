-- Evansen Co Living PMS — Guest Payments + Additional Charges (guest folio).
--
--  * Guest Payments (table reservation_misc_payments, now with a type):
--      Room Payment / Electricity Payment / Misc Payment, positive or negative, with notes.
--  * Additional Charges (new table reservation_charges): Electricity / Misc, with notes.
--  * Room payment status is no longer chosen by hand. It is worked out from the Room Payments
--    compared with room revenue:  0 → Unpaid · below revenue → Partially Paid ("Deposit") · equal or more → Paid.
--    reservations.amount_paid is kept as the sum of Room Payments, so lists and reports stay fast.
--  * Security deposit only while the room is Paid (unchanged rule).
--  * No Show / Cancel move the room payment into a Misc charge + Misc payment (cancellation charge).
--
-- Run once in Supabase SQL Editor. Safe to re-run.

-- 1) Payment type on Guest Payments ------------------------------------------------------------
alter table public.reservation_misc_payments
  add column if not exists kind text not null default 'Misc';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'reservation_misc_payments_kind_check') then
    alter table public.reservation_misc_payments
      add constraint reservation_misc_payments_kind_check check (kind in ('Room', 'Electricity', 'Misc'));
  end if;
end $$;

-- 2) Additional Charges ------------------------------------------------------------------------
create table if not exists public.reservation_charges (
  id             uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  charged_on     date not null default ((now() at time zone 'Asia/Makassar')::date),
  kind           text not null check (kind in ('Electricity', 'Misc')),
  amount         numeric not null check (amount <> 0),
  notes          text not null check (length(btrim(notes)) > 0),
  created_by     text default (auth.jwt() ->> 'email'),
  created_at     timestamptz not null default now()
);
create index if not exists reservation_charges_res_idx on public.reservation_charges (reservation_id);
alter table public.reservation_charges enable row level security;
drop policy if exists "Signed-in users can read charges" on public.reservation_charges;
create policy "Signed-in users can read charges" on public.reservation_charges for select to authenticated using (true);
drop policy if exists "Signed-in users can add charges" on public.reservation_charges;
create policy "Signed-in users can add charges" on public.reservation_charges for insert to authenticated with check (true);
drop policy if exists "Signed-in users can remove charges" on public.reservation_charges;
create policy "Signed-in users can remove charges" on public.reservation_charges for delete to authenticated using (true);

-- 3) Room payment status from Room Payments ----------------------------------------------------
create or replace function public.reservation_payment_sync() returns trigger
language plpgsql set search_path = public as $$
declare paid numeric;
begin
  select coalesce(sum(amount), 0) into paid
  from reservation_misc_payments where reservation_id = new.id and kind = 'Room';
  new.amount_paid := paid;
  new.payment_status := case
    when paid <= 0 then 'Unpaid'
    when paid < coalesce(new.room_revenue, 0) then 'Deposit'      -- shown as "Partially Paid"
    else 'Paid' end;
  if new.payment_status <> 'Paid' then
    new.security_deposit := null;                                  -- deposit only alongside a paid room
  end if;
  return new;
end $$;

-- After a Room Payment is added or removed, refresh the booking (fires the trigger above)
create or replace function public.room_payment_refresh() returns trigger
language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  if tg_op = 'DELETE' then rid := old.reservation_id; else rid := new.reservation_id; end if;
  if (tg_op = 'DELETE' and old.kind = 'Room') or (tg_op <> 'DELETE' and new.kind = 'Room') then
    update reservations set amount_paid = amount_paid where id = rid;
  end if;
  return null;
end $$;
drop trigger if exists room_payment_refresh on public.reservation_misc_payments;
create trigger room_payment_refresh after insert or delete on public.reservation_misc_payments
  for each row execute function public.room_payment_refresh();

-- 4) Negative payments (refund / discount / rebate): never more than the money received ---------
create or replace function public.misc_refund_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare received numeric; refunded numeric;
begin
  if new.amount >= 0 then return new; end if;
  select coalesce(sum(amount) filter (where amount > 0), 0), coalesce(-sum(amount) filter (where amount < 0), 0)
    into received, refunded
  from reservation_misc_payments where reservation_id = new.reservation_id;
  if received <= 0 then
    raise exception 'A negative payment is only possible after money has been received on this booking.';
  end if;
  if refunded + (-new.amount) > received then
    raise exception 'Negative payments cannot be more than the money received on this booking (IDR %). Already returned: IDR %.',
      replace(to_char(received, 'FM999,999,999,999'), ',', '.'), replace(to_char(refunded, 'FM999,999,999,990'), ',', '.');
  end if;
  return new;
end $$;

-- 5) Change History for payments and charges ---------------------------------------------------
create or replace function public.misc_payment_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who text := coalesce(auth.jwt() ->> 'email', 'system');
  r   public.reservation_misc_payments;
  txt text;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  txt := r.kind || ' Payment · ' || case when r.amount < 0 then '−IDR ' else 'IDR ' end
         || replace(to_char(abs(r.amount), 'FM999,999,999,999'), ',', '.') || ' · ' || to_char(r.paid_on, 'DD Mon YYYY') || ' · ' || r.notes;
  insert into reservation_history (reservation_id, changed_by, action, changes)
  values (r.reservation_id, who,
          case when tg_op = 'DELETE' then 'Payment removed' else 'Payment added' end,
          jsonb_build_object('payment', jsonb_build_object(
            'old', case when tg_op = 'DELETE' then to_jsonb(txt) else null end,
            'new', case when tg_op = 'DELETE' then null else to_jsonb(txt) end)));
  return null;
end $$;

create or replace function public.charge_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who text := coalesce(auth.jwt() ->> 'email', 'system');
  r   public.reservation_charges;
  txt text;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  txt := r.kind || ' charge · ' || case when r.amount < 0 then '−IDR ' else 'IDR ' end
         || replace(to_char(abs(r.amount), 'FM999,999,999,999'), ',', '.') || ' · ' || to_char(r.charged_on, 'DD Mon YYYY') || ' · ' || r.notes;
  insert into reservation_history (reservation_id, changed_by, action, changes)
  values (r.reservation_id, who,
          case when tg_op = 'DELETE' then 'Charge removed' else 'Charge added' end,
          jsonb_build_object('charge', jsonb_build_object(
            'old', case when tg_op = 'DELETE' then to_jsonb(txt) else null end,
            'new', case when tg_op = 'DELETE' then null else to_jsonb(txt) end)));
  return null;
end $$;
drop trigger if exists charge_log on public.reservation_charges;
create trigger charge_log after insert or delete on public.reservation_charges
  for each row execute function public.charge_log();

-- 6) Booking change history: payment status / amount paid now come from payments (logged above)
create or replace function public.reservation_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who     text  := coalesce(auth.jwt() ->> 'email', 'system');
  diff    jsonb := '{}'::jsonb;
  k       text;
  tracked text[] := array['guest_name','country','guest_email','guest_phone','guests',
                          'emergency_contact_name','emergency_contact_phone',
                          'arrival_date','departure_date','room_name','rate','channel',
                          'status','rate_type','security_deposit',
                          'notes','room_night','room_revenue'];
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
           when coalesce(current_setting('app.room_rename', true), 'off') = 'on' then 'Room renamed'
           when new.status = 'Cancelled' and old.status is distinct from 'Cancelled' then 'Cancelled'
           when diff ? 'status' and (diff - 'status') = '{}'::jsonb then 'Status changed'
           when (diff - 'room_name' - 'arrival_date' - 'departure_date') = '{}'::jsonb then 'Moved'
           else 'Edited'
         end;

  insert into reservation_history (reservation_id, changed_by, action, changes)
  values (new.id, who, act, diff);
  return new;
end $$;

-- 7) Daily No Show job: after departure, the room payment becomes a cancellation charge ----------
create or replace function public.mark_no_shows() returns integer
language plpgsql security definer set search_path = public as $$
declare
  today date := (now() at time zone 'Asia/Makassar')::date;
  n integer := 0;
  m integer;
  r record;
  note text;
begin
  update reservations set status = 'No-show'
  where status = 'New Reservation' and arrival_date < today;
  get diagnostics m = row_count;
  n := n + m;

  for r in
    select * from reservations
    where status = 'No-show' and departure_date < today and coalesce(amount_paid, 0) > 0
  loop
    note := 'Cancellation charge – No Show, ' || r.room_night || ' room night' || case when r.room_night = 1 then '' else 's' end
            || ' (' || to_char(r.arrival_date, 'DD Mon YYYY') || ' – ' || to_char(r.departure_date, 'DD Mon YYYY') || ')';
    if coalesce(r.security_deposit, 0) > 0 then
      note := note || '. A security deposit of IDR ' || replace(to_char(r.security_deposit, 'FM999,999,999,999'), ',', '.')
              || ' was on record — refund it to the guest.';
    end if;
    insert into reservation_charges (reservation_id, charged_on, kind, amount, notes, created_by)
      values (r.id, today, 'Misc', r.amount_paid, note, 'system');
    insert into reservation_misc_payments (reservation_id, paid_on, kind, amount, notes, created_by)
      values (r.id, today, 'Misc', r.amount_paid, note, 'system');
    insert into reservation_misc_payments (reservation_id, paid_on, kind, amount, notes, created_by)
      values (r.id, today, 'Room', -r.amount_paid, 'Moved to Misc Payment – ' || note, 'system');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.mark_no_shows() from public;
grant execute on function public.mark_no_shows() to anon, authenticated;

-- 8) Cancel a booking with money on it ---------------------------------------------------------
create or replace function public.cancel_with_misc(p_id uuid) returns void
language plpgsql set search_path = public as $$
declare
  r     reservations;
  today date := (now() at time zone 'Asia/Makassar')::date;
  stay  text;
begin
  select * into r from reservations where id = p_id for update;
  if not found then raise exception 'Reservation not found.'; end if;
  if r.status = 'Cancelled' then raise exception 'This reservation is already cancelled.'; end if;
  if r.status in ('Checked-in', 'Checked-out') then raise exception 'A checked-in or checked-out reservation cannot be cancelled.'; end if;

  stay := r.room_night || ' room night' || case when r.room_night = 1 then '' else 's' end
          || ' (' || to_char(r.arrival_date, 'DD Mon YYYY') || ' – ' || to_char(r.departure_date, 'DD Mon YYYY') || ')';

  if coalesce(r.amount_paid, 0) > 0 then
    insert into reservation_charges (reservation_id, charged_on, kind, amount, notes)
      values (r.id, today, 'Misc', r.amount_paid, 'Cancellation room charge – ' || stay);
    insert into reservation_misc_payments (reservation_id, paid_on, kind, amount, notes)
      values (r.id, today, 'Misc', r.amount_paid, 'Cancellation room charge – ' || stay);
    insert into reservation_misc_payments (reservation_id, paid_on, kind, amount, notes)
      values (r.id, today, 'Room', -r.amount_paid, 'Moved to Misc Payment – cancellation, ' || stay);
  end if;
  if coalesce(r.security_deposit, 0) > 0 then
    insert into reservation_charges (reservation_id, charged_on, kind, amount, notes)
      values (r.id, today, 'Misc', r.security_deposit, 'Cancellation security deposit charge – ' || stay);
    insert into reservation_misc_payments (reservation_id, paid_on, kind, amount, notes)
      values (r.id, today, 'Misc', r.security_deposit, 'Cancellation security deposit charge – ' || stay);
  end if;

  update reservations set status = 'Cancelled', security_deposit = null where id = r.id;
end $$;
revoke all on function public.cancel_with_misc(uuid) from public;
grant execute on function public.cancel_with_misc(uuid) to authenticated;

-- 9) Edge function backups include the new table
-- (nothing to do here; see supabase/functions/google/index.ts BACKUP_TABLES)

select 'guest payments ready' as status,
       (select count(*) from reservation_misc_payments) as payments,
       (select count(*) from reservation_charges) as charges;

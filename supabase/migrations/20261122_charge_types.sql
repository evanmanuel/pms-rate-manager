-- Evansen Co Living PMS — Guest Payments = money received only (positive).
-- Additional Charges types: Electricity, Misc (guest owes more), Rebate (guest owes less, lowers revenue),
-- Refund (money handed back to the guest, with a method). Rebate / Refund are stored as negative amounts.

-- 1) Charges: new types, method for refunds, sign by type
alter table public.reservation_charges add column if not exists method text;
alter table public.reservation_charges drop constraint if exists reservation_charges_kind_check;
alter table public.reservation_charges drop constraint if exists reservation_charges_amount_check;
alter table public.reservation_charges drop constraint if exists reservation_charges_sign_check;
alter table public.reservation_charges drop constraint if exists reservation_charges_method_check;
alter table public.reservation_charges add constraint reservation_charges_kind_check
  check (kind in ('Electricity', 'Misc', 'Rebate', 'Refund'));

-- 2) Move any negative Guest Payments into charges
--    negative Room payment  → Refund (money returned)
--    negative Elec/Misc     → Rebate (owes less) + Refund (money returned)
insert into public.reservation_charges (reservation_id, charged_on, kind, amount, notes, created_by, created_at, method)
select reservation_id, paid_on, 'Refund', amount, notes, created_by, created_at,
       case when method in ('Cash', 'Bank Transfer', 'QRIS', 'OTA Collect') then method else 'Cash' end
from public.reservation_misc_payments where amount < 0;
insert into public.reservation_charges (reservation_id, charged_on, kind, amount, notes, created_by, created_at)
select reservation_id, paid_on, 'Rebate', amount, notes, created_by, created_at
from public.reservation_misc_payments where amount < 0 and kind <> 'Room';
delete from public.reservation_misc_payments where amount < 0;

alter table public.reservation_charges add constraint reservation_charges_sign_check
  check ((kind in ('Electricity', 'Misc') and amount > 0) or (kind in ('Rebate', 'Refund') and amount < 0));
alter table public.reservation_charges add constraint reservation_charges_method_check
  check ((kind = 'Refund' and method in ('Cash', 'Bank Transfer', 'QRIS', 'OTA Collect')) or (kind <> 'Refund' and method is null));

-- 3) Guest Payments: positive only
alter table public.reservation_misc_payments drop constraint if exists reservation_misc_payments_positive_check;
alter table public.reservation_misc_payments add constraint reservation_misc_payments_positive_check check (amount > 0);
drop trigger if exists misc_refund_check on public.reservation_misc_payments;

-- 4) A refund can't be more than the money received (minus earlier refunds)
create or replace function public.charge_refund_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare received numeric; refunded numeric;
begin
  if new.kind <> 'Refund' then return new; end if;
  select coalesce(sum(amount), 0) into received from reservation_misc_payments where reservation_id = new.reservation_id;
  select coalesce(-sum(amount), 0) into refunded from reservation_charges where reservation_id = new.reservation_id and kind = 'Refund';
  if refunded + (-new.amount) > received then
    raise exception 'A refund cannot be more than the money received on this booking (IDR %). Already refunded: IDR %.',
      replace(to_char(received, 'FM999,999,999,990'), ',', '.'), replace(to_char(refunded, 'FM999,999,999,990'), ',', '.');
  end if;
  return new;
end $$;
drop trigger if exists charge_refund_check on public.reservation_charges;
create trigger charge_refund_check before insert on public.reservation_charges
  for each row execute function public.charge_refund_check();

-- 5) History text for charges (shows the refund method)
create or replace function public.charge_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who text := coalesce(auth.jwt() ->> 'email', 'system');
  r   public.reservation_charges;
  txt text;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  txt := r.kind || case when r.kind in ('Rebate', 'Refund') then '' else ' charge' end || ' · '
         || case when r.amount < 0 then '−IDR ' else 'IDR ' end
         || replace(to_char(abs(r.amount), 'FM999,999,999,999'), ',', '.')
         || case when r.method is not null then ' · ' || r.method else '' end
         || ' · ' || to_char(r.charged_on, 'DD Mon YYYY') || ' · ' || r.notes;
  insert into reservation_history (reservation_id, changed_by, action, changes)
  values (r.reservation_id, who,
          case when tg_op = 'DELETE' then 'Charge removed' else 'Charge added' end,
          jsonb_build_object('charge', jsonb_build_object(
            'old', case when tg_op = 'DELETE' then to_jsonb(txt) else null end,
            'new', case when tg_op = 'DELETE' then null else to_jsonb(txt) end)));
  return null;
end $$;

-- 6) Daily No Show job: after departure, keep the room payment and add a Misc cancellation charge (once)
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
    select * from reservations x
    where x.status = 'No-show' and x.departure_date < today and coalesce(x.amount_paid, 0) > 0
      and not exists (select 1 from reservation_charges c where c.reservation_id = x.id and c.notes like 'Cancellation charge – No Show%')
  loop
    note := 'Cancellation charge – No Show, ' || r.room_night || ' room night' || case when r.room_night = 1 then '' else 's' end
            || ' (' || to_char(r.arrival_date, 'DD Mon YYYY') || ' – ' || to_char(r.departure_date, 'DD Mon YYYY') || ')';
    if coalesce(r.security_deposit, 0) > 0 then
      note := note || '. A security deposit of IDR ' || replace(to_char(r.security_deposit, 'FM999,999,999,999'), ',', '.')
              || ' was on record — refund it to the guest.';
    end if;
    insert into reservation_charges (reservation_id, charged_on, kind, amount, notes, created_by)
      values (r.id, today, 'Misc', r.amount_paid, note, 'system');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.mark_no_shows() from public;
grant execute on function public.mark_no_shows() to anon, authenticated;

-- 7) Cancel with money: keep the payments, charge them as a Misc cancellation charge
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
  end if;
  if coalesce(r.security_deposit, 0) > 0 then
    -- the deposit was held outside the payments: record it as received and charge it
    insert into reservation_misc_payments (reservation_id, paid_on, kind, method, amount, notes)
      values (r.id, today, 'Misc', 'Internal', r.security_deposit, 'Security deposit kept – cancellation, ' || stay);
    insert into reservation_charges (reservation_id, charged_on, kind, amount, notes)
      values (r.id, today, 'Misc', r.security_deposit, 'Cancellation security deposit charge – ' || stay);
  end if;

  update reservations set status = 'Cancelled', security_deposit = null where id = r.id;
end $$;
revoke all on function public.cancel_with_misc(uuid) from public;
grant execute on function public.cancel_with_misc(uuid) to authenticated;

select 'charge types ready' as status,
       (select count(*) from reservation_charges where kind in ('Rebate', 'Refund')) as rebates_refunds,
       (select count(*) from reservation_misc_payments where amount < 0) as negative_payments_left;

-- Evansen Co Living PMS — cancelling a booking that has a room payment and/or security deposit.
-- Moves the room payment and the security deposit into Misc Payment and cancels the booking, all in one step
-- (if anything fails, nothing changes). Runs as the signed-in staff member, so history shows their name.
-- Run once in Supabase SQL Editor. Safe to re-run.

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
    insert into reservation_misc_payments (reservation_id, paid_on, amount, notes)
    values (r.id, today, r.amount_paid, 'Cancellation room charge – ' || stay);
  end if;
  if coalesce(r.security_deposit, 0) > 0 then
    insert into reservation_misc_payments (reservation_id, paid_on, amount, notes)
    values (r.id, today, r.security_deposit, 'Cancellation security deposit charge – ' || stay);
  end if;

  -- Cancel, and clear the room payment / deposit so the money is only counted once (as Misc Payment)
  update reservations set status = 'Cancelled', payment_status = 'Unpaid', amount_paid = 0, security_deposit = null
  where id = r.id;
end $$;
revoke all on function public.cancel_with_misc(uuid) from public;
grant execute on function public.cancel_with_misc(uuid) to authenticated;

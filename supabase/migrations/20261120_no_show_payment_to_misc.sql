-- Evansen Co Living PMS — No Show handling, part 2.
-- After a No Show guest's departure date has passed, the room payment is moved into Misc Payment
-- as a cancellation charge (room payment on the booking goes back to Unpaid / 0, so nothing is counted twice).
-- Runs inside mark_no_shows(), which the daily GitHub job calls at 00:05 Bali time. Run once in SQL Editor. Safe to re-run.

create or replace function public.mark_no_shows() returns integer
language plpgsql security definer set search_path = public as $$
declare
  today date := (now() at time zone 'Asia/Makassar')::date;
  n integer := 0;
  m integer;
  r record;
  note text;
begin
  -- 1) Not checked in by the day after arrival -> No Show
  update reservations set status = 'No-show'
  where status = 'New Reservation' and arrival_date < today;
  get diagnostics m = row_count;
  n := n + m;

  -- 2) No Show whose departure has passed and that has a room payment -> move it to Misc Payment
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
    insert into reservation_misc_payments (reservation_id, paid_on, amount, notes, created_by)
    values (r.id, today, r.amount_paid, note, 'system');
    update reservations set payment_status = 'Unpaid', amount_paid = 0 where id = r.id;
    n := n + 1;
  end loop;

  return n;
end $$;
revoke all on function public.mark_no_shows() from public;
grant execute on function public.mark_no_shows() to anon, authenticated;

select public.mark_no_shows() as changes_made;

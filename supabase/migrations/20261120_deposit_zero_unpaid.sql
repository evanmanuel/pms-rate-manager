-- Evansen Co Living PMS — payment status "Deposit" only when something was actually paid.
-- A "Deposit" with IDR 0 paid is saved as "Unpaid". Run once in Supabase SQL Editor. Safe to re-run.

create or replace function public.reservation_payment_sync() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.payment_status = 'Paid' then
    new.amount_paid := coalesce(new.room_revenue, 0);
  elsif new.payment_status = 'Deposit' then
    new.amount_paid := least(greatest(coalesce(new.amount_paid, 0), 0), coalesce(new.room_revenue, 0));
    if new.amount_paid <= 0 then
      new.payment_status := 'Unpaid';
      new.amount_paid := 0;
    end if;
  else
    new.amount_paid := 0;
  end if;
  return new;
end $$;

-- Existing bookings saved as "Deposit" with nothing paid (cancelled bookings stay locked; the app shows them as Unpaid)
update public.reservations set payment_status = 'Unpaid'
where payment_status = 'Deposit' and coalesce(amount_paid, 0) <= 0 and status <> 'Cancelled';

select confirmation_number, guest_name, status, payment_status, amount_paid
from public.reservations where payment_status = 'Deposit' order by confirmation_number;

-- Evansen Co Living PMS — Refundable Security Deposit can only be recorded when Payment Status is Paid.
-- Run once in Supabase SQL Editor. Safe to re-run.

create or replace function public.reservation_payment_sync() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.payment_status = 'Paid' then
    new.amount_paid := coalesce(new.room_revenue, 0);
  elsif new.payment_status = 'Deposit' then   -- shown in the app as "Partially Paid"
    new.amount_paid := least(greatest(coalesce(new.amount_paid, 0), 0), coalesce(new.room_revenue, 0));
    if new.amount_paid <= 0 then
      new.payment_status := 'Unpaid';
      new.amount_paid := 0;
    end if;
  else
    new.amount_paid := 0;
  end if;
  -- Security deposit only alongside a fully paid room
  if new.payment_status <> 'Paid' then
    new.security_deposit := null;
  end if;
  return new;
end $$;

select confirmation_number, guest_name, status, payment_status, security_deposit
from public.reservations where security_deposit is not null order by confirmation_number;

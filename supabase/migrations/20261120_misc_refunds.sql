-- Evansen Co Living PMS — Misc Payment refunds / rebates (negative amounts).
-- A refund is only possible when money was received on the booking (room payment and/or Misc charges),
-- and refunds can never add up to more than that money. Run once in Supabase SQL Editor. Safe to re-run.

alter table public.reservation_misc_payments drop constraint if exists reservation_misc_payments_amount_check;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'reservation_misc_payments_amount_nonzero') then
    alter table public.reservation_misc_payments add constraint reservation_misc_payments_amount_nonzero check (amount <> 0);
  end if;
end $$;

create or replace function public.misc_refund_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare received numeric; refunded numeric;
begin
  if new.amount >= 0 then return new; end if;
  select coalesce(r.amount_paid, 0)
         + coalesce((select sum(amount) from reservation_misc_payments where reservation_id = r.id and amount > 0), 0)
    into received from reservations r where r.id = new.reservation_id;
  select coalesce(-sum(amount), 0) into refunded from reservation_misc_payments where reservation_id = new.reservation_id and amount < 0;
  if coalesce(received, 0) <= 0 then
    raise exception 'A refund is only possible after money has been received on this booking.';
  end if;
  if refunded + (-new.amount) > received then
    raise exception 'Refunds cannot be more than the money received on this booking (IDR %). Already refunded: IDR %.',
      replace(to_char(received, 'FM999,999,999,999'), ',', '.'), replace(to_char(refunded, 'FM999,999,999,990'), ',', '.');
  end if;
  return new;
end $$;
drop trigger if exists misc_refund_check on public.reservation_misc_payments;
create trigger misc_refund_check before insert on public.reservation_misc_payments
  for each row execute function public.misc_refund_check();

-- History text: show refunds as "−IDR …"
create or replace function public.misc_payment_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who text := coalesce(auth.jwt() ->> 'email', 'system');
  r   public.reservation_misc_payments;
  txt text;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  txt := case when r.amount < 0 then '−IDR ' else 'IDR ' end
         || replace(to_char(abs(r.amount), 'FM999,999,999,999'), ',', '.') || ' · ' || to_char(r.paid_on, 'DD Mon YYYY') || ' · ' || r.notes;
  insert into reservation_history (reservation_id, changed_by, action, changes)
  values (r.reservation_id, who,
          case when tg_op = 'DELETE' then 'Misc payment removed' else 'Misc payment added' end,
          jsonb_build_object('misc_payment', jsonb_build_object(
            'old', case when tg_op = 'DELETE' then to_jsonb(txt) else null end,
            'new', case when tg_op = 'DELETE' then null else to_jsonb(txt) end)));
  return null;
end $$;

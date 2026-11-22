-- Evansen Co Living PMS — payment method on Guest Payments (for daily reconciliation).
-- Cash / Bank Transfer / QRIS / OTA Collect; "Internal" for money the system moves itself (No Show / cancellation).
alter table public.reservation_misc_payments add column if not exists method text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'reservation_misc_payments_method_check') then
    alter table public.reservation_misc_payments
      add constraint reservation_misc_payments_method_check
      check (method is null or method in ('Cash', 'Bank Transfer', 'QRIS', 'OTA Collect', 'Internal'));
  end if;
end $$;
update public.reservation_misc_payments set method = 'Internal' where method is null and created_by = 'system';
alter table public.reservation_misc_payments alter column method set default 'Internal';

-- History line shows the method
create or replace function public.misc_payment_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who text := coalesce(auth.jwt() ->> 'email', 'system');
  r   public.reservation_misc_payments;
  txt text;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  txt := r.kind || ' Payment · ' || case when r.amount < 0 then '−IDR ' else 'IDR ' end
         || replace(to_char(abs(r.amount), 'FM999,999,999,999'), ',', '.') || ' · ' || coalesce(r.method, '—')
         || ' · ' || to_char(r.paid_on, 'DD Mon YYYY') || ' · ' || r.notes;
  insert into reservation_history (reservation_id, changed_by, action, changes)
  values (r.reservation_id, who,
          case when tg_op = 'DELETE' then 'Payment removed' else 'Payment added' end,
          jsonb_build_object('payment', jsonb_build_object(
            'old', case when tg_op = 'DELETE' then to_jsonb(txt) else null end,
            'new', case when tg_op = 'DELETE' then null else to_jsonb(txt) end)));
  return null;
end $$;

select 'payment method ready' as status;

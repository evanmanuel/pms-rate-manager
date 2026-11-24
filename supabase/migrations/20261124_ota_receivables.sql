-- Evansen Co Living PMS — OTA Receivables: reconcile OTA Collect payments when the OTA pays out.
alter table public.reservation_misc_payments add column if not exists ota_received_on date;
alter table public.reservation_misc_payments add column if not exists ota_received_by text;

-- Signed-in users may update a payment, but only the OTA payout fields (amount, type, method… stay fixed)
drop policy if exists "Signed-in users can reconcile OTA payouts" on public.reservation_misc_payments;
create policy "Signed-in users can reconcile OTA payouts" on public.reservation_misc_payments
  for update to authenticated using (true) with check (true);

create or replace function public.ota_payout_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text := coalesce(auth.jwt() ->> 'email', 'system'); txt text;
begin
  if (to_jsonb(new) - 'ota_received_on' - 'ota_received_by')
     is distinct from (to_jsonb(old) - 'ota_received_on' - 'ota_received_by') then
    raise exception 'Only the OTA payout details of a payment can be changed. Delete and re-enter the payment instead.';
  end if;
  if new.ota_received_on is not null and coalesce(old.method, '') <> 'OTA Collect' then
    raise exception 'Only OTA Collect payments can be marked as received from the OTA.';
  end if;
  if new.ota_received_on is null then new.ota_received_by := null;
  else new.ota_received_by := who; end if;

  if new.ota_received_on is distinct from old.ota_received_on then
    txt := new.kind || ' Payment IDR ' || replace(to_char(new.amount, 'FM999,999,999,999'), ',', '.') || ' (' || new.notes || ')'
        || case when new.ota_received_on is null then ' — OTA payout mark removed'
                else ' — OTA payout received ' || to_char(new.ota_received_on, 'DD Mon YYYY') end;
    insert into reservation_history (reservation_id, changed_by, action, changes)
    values (new.reservation_id, who, case when new.ota_received_on is null then 'OTA payout undone' else 'OTA payout received' end,
            jsonb_build_object('payment', jsonb_build_object('old', null, 'new', to_jsonb(txt))));
  end if;
  return new;
end $$;
drop trigger if exists ota_payout_guard on public.reservation_misc_payments;
create trigger ota_payout_guard before update on public.reservation_misc_payments
  for each row execute function public.ota_payout_guard();

select 'ota receivables ready' as status;

-- Evansen Co Living PMS — amount paid (deposit / paid) + emergency contact
-- Run once in Supabase SQL Editor. Safe to re-run.

-- 1) New fields
alter table public.reservations
  add column if not exists amount_paid             numeric not null default 0,
  add column if not exists emergency_contact_name  text,
  add column if not exists emergency_contact_phone text;

-- 2) Keep amount_paid consistent with payment status:
--    Paid → the full total, Unpaid → 0, Deposit → the amount entered (never above the total)
create or replace function public.reservation_payment_sync() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.payment_status = 'Paid' then
    new.amount_paid := coalesce(new.room_revenue, 0);
  elsif new.payment_status = 'Deposit' then
    new.amount_paid := least(greatest(coalesce(new.amount_paid, 0), 0), coalesce(new.room_revenue, 0));
  else
    new.amount_paid := 0;
  end if;
  return new;
end $$;

drop trigger if exists reservation_payment_sync on public.reservations;
create trigger reservation_payment_sync
  before insert or update on public.reservations
  for each row execute function public.reservation_payment_sync();

-- Existing "Paid" bookings: record them as fully paid
update public.reservations set amount_paid = room_revenue
where payment_status = 'Paid' and amount_paid is distinct from room_revenue and status <> 'Cancelled';

-- 3) History log: also track the new fields (room-rename logic unchanged)
create or replace function public.reservation_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who     text  := coalesce(auth.jwt() ->> 'email', 'system');
  diff    jsonb := '{}'::jsonb;
  k       text;
  tracked text[] := array['guest_name','country','guest_email','guest_phone','guests',
                          'emergency_contact_name','emergency_contact_phone',
                          'arrival_date','departure_date','room_name','rate','channel',
                          'status','payment_status','amount_paid','notes','room_night','room_revenue'];
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
           else 'Edited'
         end;

  insert into reservation_history (reservation_id, changed_by, action, changes)
  values (new.id, who, act, diff);
  return new;
end $$;

-- 4) Check
select confirmation_number, payment_status, room_revenue, amount_paid from public.reservations order by arrival_date;

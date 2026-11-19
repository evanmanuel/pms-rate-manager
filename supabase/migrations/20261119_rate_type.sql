-- Evansen Co Living PMS — how a booking was priced: per night or total stay
-- Run once in Supabase SQL Editor. Safe to re-run.

alter table public.reservations add column if not exists rate_type text not null default 'per_night';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'reservations_rate_type_check') then
    alter table public.reservations add constraint reservations_rate_type_check check (rate_type in ('per_night','total'));
  end if;
end $$;

-- History log: also track rate_type
create or replace function public.reservation_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who     text  := coalesce(auth.jwt() ->> 'email', 'system');
  diff    jsonb := '{}'::jsonb;
  k       text;
  tracked text[] := array['guest_name','country','guest_email','guest_phone','guests',
                          'emergency_contact_name','emergency_contact_phone',
                          'arrival_date','departure_date','room_name','rate','channel',
                          'status','payment_status','amount_paid','rate_type','notes','room_night','room_revenue'];
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


select rate_type, count(*) from public.reservations group by rate_type;

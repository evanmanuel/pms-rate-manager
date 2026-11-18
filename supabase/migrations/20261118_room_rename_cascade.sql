-- Evansen Co Living PMS — renaming a room updates its reservations
-- Run once in Supabase SQL Editor. Safe to re-run.

-- 1) Room rules: no empty or duplicate names; a room with bookings can't be deleted
create or replace function public.rooms_before_change() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from reservations where room_name = old.name) then
      raise exception 'Room "%" has reservations and cannot be removed. Rename it instead.', old.name;
    end if;
    return old;
  end if;
  new.name := btrim(coalesce(new.name, ''));
  if new.name = '' then
    raise exception 'Room name cannot be empty.';
  end if;
  if exists (select 1 from rooms where lower(name) = lower(new.name) and id <> new.id) then
    raise exception 'A room named "%" already exists.', new.name;
  end if;
  return new;
end $$;

drop trigger if exists rooms_before_change on public.rooms;
create trigger rooms_before_change
  before insert or update or delete on public.rooms
  for each row execute function public.rooms_before_change();

-- 2) After a rename, move every reservation (including cancelled) to the new name
create or replace function public.rooms_after_rename() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.name is distinct from old.name then
    perform set_config('app.room_rename', 'on', true);
    update reservations set room_name = new.name where room_name = old.name;
    perform set_config('app.room_rename', 'off', true);
  end if;
  return new;
end $$;

drop trigger if exists rooms_after_rename on public.rooms;
create trigger rooms_after_rename
  after update of name on public.rooms
  for each row execute function public.rooms_after_rename();

-- 3) Reservation lock: allow the room-name change on cancelled bookings during a rename
create or replace function public.reservation_before_update() returns trigger
language plpgsql set search_path = public as $$
declare
  renaming boolean := coalesce(current_setting('app.room_rename', true), 'off') = 'on';
begin
  if old.status = 'Cancelled' and not renaming then
    -- A cancelled booking is final. Only internal notes may still be added.
    if (to_jsonb(new) - 'notes' - 'updated_at' - 'updated_by')
       is distinct from (to_jsonb(old) - 'notes' - 'updated_at' - 'updated_by') then
      raise exception 'This reservation is cancelled and can no longer be changed. Please create a new booking.';
    end if;
  end if;
  if new.confirmation_number is distinct from old.confirmation_number then
    raise exception 'The confirmation number cannot be changed.';
  end if;
  new.updated_at := now();
  new.updated_by := coalesce(auth.jwt() ->> 'email', 'system');
  return new;
end $$;

-- 4) History: label these entries "Room renamed"
create or replace function public.reservation_log_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who     text  := coalesce(auth.jwt() ->> 'email', 'system');
  diff    jsonb := '{}'::jsonb;
  k       text;
  tracked text[] := array['guest_name','country','guest_email','guest_phone','guests',
                          'arrival_date','departure_date','room_name','rate','channel',
                          'status','payment_status','notes','room_night','room_revenue'];
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

-- 5) Check: rooms and how many reservations each has
select r.name, count(x.id) as reservations
from public.rooms r left join public.reservations x on x.room_name = r.name
group by r.name, r.created_at order by r.created_at;

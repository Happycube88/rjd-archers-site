-- RJD Archers: club night booking.  Safe to run more than once.  Run AFTER tournaments.sql.
--  * Committee creates nights (indoor or outdoor).
--  * Booking opens 5pm the day before and closes 5pm on the day (UK time).
--  * Adult members/guests book themselves; only a parent/guardian books an under-18.
--  * Committee and Session leads see the attendee list.

create table if not exists public.club_nights (
  id             uuid primary key default gen_random_uuid(),
  night_date     date not null,
  kind           text not null check (kind in ('indoor','outdoor')),
  venue          text check (char_length(venue) <= 200),
  range_distance integer check (range_distance is null or range_distance between 1 and 200),
  range_unit     text check (range_unit in ('yards','metres')),
  target_size    text check (char_length(target_size) <= 40),   -- indoor
  target_type    text check (char_length(target_type) <= 60),   -- indoor
  max_places     integer check (max_places is null or max_places > 0),
  fee            numeric(6,2) check (fee is null or fee >= 0),
  notes          text check (char_length(notes) <= 500),
  created_at     timestamptz not null default now(),
  constraint club_night_indoor_rules check (kind <> 'indoor' or
     (target_size is not null and target_type is not null and max_places is not null and max_places <= 26
      and range_distance is not null and range_unit is not null)),
  constraint club_night_outdoor_rules check (kind <> 'outdoor' or (range_distance is not null and range_unit is not null))
);
create index if not exists club_nights_date_idx on public.club_nights(night_date);
alter table public.club_nights enable row level security;
drop policy if exists cn_read  on public.club_nights;
drop policy if exists cn_write on public.club_nights;
drop policy if exists cn_aal2i on public.club_nights;
drop policy if exists cn_aal2u on public.club_nights;
drop policy if exists cn_aal2d on public.club_nights;
create policy cn_read  on public.club_nights for select to anon, authenticated using (true);
create policy cn_write on public.club_nights for all to authenticated using (public.is_committee()) with check (public.is_committee());
create policy cn_aal2i on public.club_nights as restrictive for insert to authenticated with check (public.is_aal2());
create policy cn_aal2u on public.club_nights as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy cn_aal2d on public.club_nights as restrictive for delete to authenticated using (public.is_aal2());
revoke all on public.club_nights from anon, authenticated;
grant select on public.club_nights to anon;
grant select, insert, update, delete on public.club_nights to authenticated;

create table if not exists public.club_night_bookings (
  id         uuid primary key default gen_random_uuid(),
  night_id   uuid not null references public.club_nights(id) on delete cascade,
  member_id  uuid not null references public.members(id) on delete cascade,
  booked_by  uuid,
  status     text not null default 'booked' check (status in ('booked','cancelled')),
  paid       boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists club_night_bookings_once on public.club_night_bookings(night_id, member_id) where status = 'booked';
alter table public.club_night_bookings enable row level security;
drop policy if exists cnb_read      on public.club_night_bookings;
drop policy if exists cnb_committee on public.club_night_bookings;
drop policy if exists cnb_aal2i     on public.club_night_bookings;
drop policy if exists cnb_aal2u     on public.club_night_bookings;
drop policy if exists cnb_aal2d     on public.club_night_bookings;
create policy cnb_read on public.club_night_bookings for select to authenticated
  using (public.is_committee() or booked_by = auth.uid() or member_id = public.my_member_id() or public.is_guardian_of(member_id));
create policy cnb_committee on public.club_night_bookings for all to authenticated using (public.is_committee()) with check (public.is_committee());
create policy cnb_aal2i on public.club_night_bookings as restrictive for insert to authenticated with check (public.is_aal2());
create policy cnb_aal2u on public.club_night_bookings as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy cnb_aal2d on public.club_night_bookings as restrictive for delete to authenticated using (public.is_aal2());
revoke all on public.club_night_bookings from anon, authenticated;
grant select, insert, update, delete on public.club_night_bookings to authenticated;

-- Booking window: 5pm the day before until 5pm on the day, UK time
create or replace function public.club_night_open(p_date date)
returns boolean language sql stable as $$
  select (now() at time zone 'Europe/London') >= ((p_date - 1)::timestamp + time '17:00')
     and (now() at time zone 'Europe/London') <  ( p_date::timestamp      + time '17:00');
$$;
grant execute on function public.club_night_open(date) to anon, authenticated;

-- Places taken (count only; anyone can see)
create or replace function public.club_night_places(p_night uuid)
returns table(taken integer, max_places integer) language sql stable security definer set search_path = public as $$
  select (select count(*)::int from club_night_bookings b where b.night_id = n.id and b.status = 'booked'), n.max_places
    from club_nights n where n.id = p_night;
$$;
grant execute on function public.club_night_places(uuid) to anon, authenticated;

create or replace function public._can_book_for(p_member uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare m public.members;
begin
  if public.is_committee() then return true; end if;
  select * into m from members where id = p_member;
  if not found then return false; end if;
  if public.is_guardian_of(p_member) then return true; end if;
  -- an adult books for themselves; an under-18 never books for themselves
  return p_member = public.my_member_id() and m.dob is not null and m.dob <= (current_date - interval '18 years');
end $$;
revoke execute on function public._can_book_for(uuid) from public, anon, authenticated;

create or replace function public.book_club_night(p_night uuid, p_member uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare n public.club_nights; m public.members; v_taken int; v_id uuid;
begin
  if auth.uid() is null or not public.is_aal2() then raise exception 'Sign in with your 2FA code first.' using errcode = '42501'; end if;
  select * into n from club_nights where id = p_night for update;
  if not found then raise exception 'Club night not found.' using errcode = '22023'; end if;
  select * into m from members where id = p_member;
  if not found or m.membertype not in ('member','guest') then
    raise exception 'Only members and registered guests can book.' using errcode = '42501';
  end if;
  if not public._can_book_for(p_member) then
    raise exception 'Adults book for themselves; only a parent or guardian can book for an under-18.' using errcode = '42501';
  end if;
  if not public.is_committee() and not public.club_night_open(n.night_date) then
    raise exception 'Booking opens at 5pm the day before and closes at 5pm on the day.' using errcode = '22023';
  end if;
  select count(*) into v_taken from club_night_bookings where night_id = p_night and status = 'booked';
  if n.max_places is not null and v_taken >= n.max_places then
    raise exception 'This night is full (% places).', n.max_places using errcode = '22023';
  end if;
  insert into club_night_bookings(night_id, member_id, booked_by) values (p_night, p_member, auth.uid()) returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.book_club_night(uuid,uuid) from public, anon;
grant  execute on function public.book_club_night(uuid,uuid) to authenticated;

create or replace function public.cancel_club_night_booking(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b public.club_night_bookings; n public.club_nights;
begin
  if auth.uid() is null or not public.is_aal2() then raise exception 'Sign in with your 2FA code first.' using errcode = '42501'; end if;
  select * into b from club_night_bookings where id = p_id;
  if not found then raise exception 'Booking not found.' using errcode = '22023'; end if;
  if not public._can_book_for(b.member_id) then raise exception 'Not your booking.' using errcode = '42501'; end if;
  select * into n from club_nights where id = b.night_id;
  if not public.is_committee() and (now() at time zone 'Europe/London') >= (n.night_date::timestamp + time '17:00') then
    raise exception 'This night has finished.' using errcode = '22023';
  end if;
  update club_night_bookings set status = 'cancelled' where id = p_id;
end $$;
revoke execute on function public.cancel_club_night_booking(uuid) from public, anon;
grant  execute on function public.cancel_club_night_booking(uuid) to authenticated;

-- Attendee list: committee and session leads only
create or replace function public.club_night_attendees(p_night uuid)
returns table(booking_id uuid, member_name text, is_junior boolean, first_aider boolean, club text, paid boolean, booked_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_aal2() or not (public.is_committee() or public.is_session_lead()) then
    raise exception 'Committee or session leads with 2FA only.' using errcode = '42501';
  end if;
  return query
    select b.id, m.name, (m.dob is not null and m.dob > current_date - interval '18 years'), coalesce(m.firstaider,false),
           case when m.membertype = 'guest' then coalesce(nullif(m.home_club,''),'Guest') else 'RJD Archers' end,
           b.paid, b.created_at
      from club_night_bookings b join members m on m.id = b.member_id
     where b.night_id = p_night and b.status = 'booked' order by b.created_at;
end $$;
revoke execute on function public.club_night_attendees(uuid) from public, anon;
grant  execute on function public.club_night_attendees(uuid) to authenticated;

create or replace function public.committee_set_booking_paid(p_id uuid, p_paid boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_committee() or not public.is_aal2() then raise exception 'Committee with 2FA only.' using errcode = '42501'; end if;
  update club_night_bookings set paid = p_paid where id = p_id;
end $$;
revoke execute on function public.committee_set_booking_paid(uuid,boolean) from public, anon;
grant  execute on function public.committee_set_booking_paid(uuid,boolean) to authenticated;

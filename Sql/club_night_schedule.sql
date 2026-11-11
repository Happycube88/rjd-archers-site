-- RJD Archers: automatic club nights.  Safe to run more than once.  Run AFTER club_nights.sql.
--  * Weekly pattern (Tuesday and Friday, 18:00-20:00) creates club nights ahead of time.
--  * October to May = indoor, June to September = outdoor (months are editable below).
--  * The committee can move, re-time or cancel any single night (bank holidays, Christmas...).
--    A moved or cancelled night is NOT recreated by the generator.

alter table public.club_nights add column if not exists start_time time;
alter table public.club_nights add column if not exists end_time   time;
alter table public.club_nights add column if not exists cancelled  boolean not null default false;
alter table public.club_nights add column if not exists cancel_reason text check (char_length(cancel_reason) <= 200);
alter table public.club_nights add column if not exists generated_for date;   -- the pattern date this night came from
drop index if exists public.club_nights_generated_once;
create unique index if not exists club_nights_generated_once on public.club_nights(generated_for) where generated_for is not null;

-- 1. The weekly pattern
create table if not exists public.club_night_rules (
  id         serial primary key,
  weekday    integer not null check (weekday between 0 and 6),   -- 0 Sunday ... 2 Tuesday ... 5 Friday
  start_time time not null default '18:00',
  end_time   time not null default '20:00',
  active     boolean not null default true,
  unique (weekday)
);
insert into public.club_night_rules(weekday) values (2),(5) on conflict (weekday) do nothing;

-- 2. Defaults for generated nights (the committee can still change any single night)
create table if not exists public.club_night_defaults (
  kind           text primary key check (kind in ('indoor','outdoor')),
  months         integer[] not null,
  venue          text,
  range_distance integer not null,
  range_unit     text not null check (range_unit in ('yards','metres')),
  target_size    text,
  target_type    text,
  max_places     integer check (max_places is null or max_places > 0),
  fee            numeric(6,2),
  check (kind <> 'indoor' or (target_size is not null and target_type is not null and max_places is not null and max_places <= 26))
);
insert into public.club_night_defaults(kind,months,venue,range_distance,range_unit,target_size,target_type,max_places) values
  ('indoor',  '{10,11,12,1,2,3,4,5}', 'Llantrisant Leisure Centre', 18, 'yards', '40cm', 'Full face', 26),
  ('outdoor', '{6,7,8,9}',            'The Old Dog Track, Rhydyfelin', 50, 'yards', null, null, null)
on conflict (kind) do nothing;

alter table public.club_night_rules    enable row level security;
alter table public.club_night_defaults enable row level security;
do $$ declare t text; begin
  foreach t in array array['club_night_rules','club_night_defaults'] loop
    execute format('drop policy if exists %I on public.%I', t||'_read', t);
    execute format('drop policy if exists %I on public.%I', t||'_write', t);
    execute format('drop policy if exists %I on public.%I', t||'_aal2', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_committee())', t||'_read', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_committee()) with check (public.is_committee())', t||'_write', t);
    execute format('create policy %I on public.%I as restrictive for all to authenticated using (public.is_aal2()) with check (public.is_aal2())', t||'_aal2', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- 3. Generator.  Committee (with 2FA) can press the button; the database owner/cron can run it too.
create or replace function public.generate_club_nights(p_weeks integer default 12)
returns integer language plpgsql security definer set search_path = public as $$
declare d date; r public.club_night_rules; df public.club_night_defaults; v_n integer := 0; v_kind text; v_cnt integer;
begin
  -- no logged-in user = the database owner (SQL editor or the weekly job); the API's anon role cannot execute this
  if not (auth.uid() is null or (public.is_committee() and public.is_aal2())) then
    raise exception 'Committee with 2FA only.' using errcode = '42501';
  end if;
  p_weeks := least(greatest(coalesce(p_weeks, 12), 1), 52);
  for d in select g::date from generate_series(current_date, current_date + (p_weeks * 7), interval '1 day') g loop
    for r in select * from club_night_rules where active and weekday = extract(dow from d)::int loop
      select kind into v_kind from club_night_defaults where extract(month from d)::int = any(months) limit 1;
      continue when v_kind is null;
      select * into df from club_night_defaults where kind = v_kind;
      insert into club_nights(night_date, kind, venue, range_distance, range_unit, target_size, target_type, max_places, fee, start_time, end_time, generated_for)
      values (d, df.kind, df.venue, df.range_distance, df.range_unit, df.target_size, df.target_type, df.max_places, df.fee, r.start_time, r.end_time, d)
      on conflict (generated_for) where generated_for is not null do nothing;
      get diagnostics v_cnt = row_count; v_n := v_n + v_cnt;
    end loop;
  end loop;
  return v_n;
end $$;
revoke execute on function public.generate_club_nights(integer) from public, anon;
grant  execute on function public.generate_club_nights(integer) to authenticated;

-- 4. Cancelled nights cannot be booked
create or replace function public.book_club_night(p_night uuid, p_member uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare n public.club_nights; m public.members; v_taken int; v_id uuid;
begin
  if auth.uid() is null or not public.is_aal2() then raise exception 'Sign in with your 2FA code first.' using errcode = '42501'; end if;
  select * into n from club_nights where id = p_night for update;
  if not found then raise exception 'Club night not found.' using errcode = '22023'; end if;
  if n.cancelled then raise exception 'This night is cancelled%.', coalesce(' (' || n.cancel_reason || ')', '') using errcode = '22023'; end if;
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

-- 5. Keep the nights topped up: weekly, if the pg_cron extension is available (Supabase: Database > Extensions).
do $$ begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname = 'rjd-generate-club-nights';
    perform cron.schedule('rjd-generate-club-nights', '0 4 * * 1', 'select public.generate_club_nights(12)');
  else
    raise notice 'pg_cron not available: use the "Create nights" button on the club nights admin page.';
  end if;
exception when others then
  raise notice 'Could not schedule the weekly job (%). Use the "Create nights" button instead.', sqlerrm;
end $$;

-- 6. Create the first 12 weeks now
select public.generate_club_nights(12) as nights_created;

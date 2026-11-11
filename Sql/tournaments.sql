-- RJD Archers: tournaments + online entry (replaces the printed/emailed Excel entry form)
-- and the new "Session lead" role.  Safe to run more than once.
-- Run AFTER guests.sql.

-- ---------------------------------------------------------------------
-- 1. Session leads (opens up / sets up club nights). Ticked by committee only.
--    Must have been in the club at least 4 years (checked from the join date).
-- ---------------------------------------------------------------------
alter table public.members add column if not exists sessionlead boolean not null default false;

create or replace function public.check_sessionlead_4yrs()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.sessionlead
     and (tg_op = 'INSERT' or old.sessionlead is distinct from new.sessionlead)
     and (new.datejoinedclub is null or new.datejoinedclub > (current_date - interval '4 years')) then
    raise exception 'A session lead must have been in the club at least 4 years (check the join date).' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists members_sessionlead_4yrs on public.members;
create trigger members_sessionlead_4yrs before insert or update on public.members
  for each row execute function public.check_sessionlead_4yrs();
revoke execute on function public.check_sessionlead_4yrs() from public, anon, authenticated;

create or replace function public.is_session_lead()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where auth_id = auth.uid() and sessionlead);
$$;
revoke execute on function public.is_session_lead() from public, anon;
grant  execute on function public.is_session_lead() to authenticated;

-- ---------------------------------------------------------------------
-- 2. Tournaments
-- ---------------------------------------------------------------------
create table if not exists public.tournaments (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(name) between 1 and 150),
  event_date      date not null,
  venue           text check (char_length(venue) <= 300),
  rounds          text[] not null default '{}',          -- choices on the entry form
  sessions        text[] not null default '{A,B}',
  closing_date    date,
  organiser_name  text,
  organiser_email text,
  organiser_phone text,
  fee_junior      numeric(6,2) not null default 12,
  fee_adult       numeric(6,2) not null default 15,
  max_entries     integer check (max_entries is null or max_entries > 0),
  ref_code        text,                                   -- payment reference letter(s)
  format_notes    text,                                   -- event format, timings, awards
  payment_info    text,                                   -- bank details: signed-in users only
  published       boolean not null default false,
  created_at      timestamptz not null default now()
);
alter table public.tournaments enable row level security;

drop policy if exists tournaments_read   on public.tournaments;
drop policy if exists tournaments_write  on public.tournaments;
drop policy if exists tournaments_aal2   on public.tournaments;
drop policy if exists tournaments_aal2u  on public.tournaments;
drop policy if exists tournaments_aal2d  on public.tournaments;
create policy tournaments_read  on public.tournaments for select to anon, authenticated using (published);
create policy tournaments_write on public.tournaments for all to authenticated
  using (public.is_committee()) with check (public.is_committee());
create policy tournaments_aal2  on public.tournaments as restrictive for insert to authenticated with check (public.is_aal2());
create policy tournaments_aal2u on public.tournaments as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy tournaments_aal2d on public.tournaments as restrictive for delete to authenticated using (public.is_aal2());

revoke all on public.tournaments from anon, authenticated;
grant select (id,name,event_date,venue,rounds,sessions,closing_date,organiser_name,organiser_email,organiser_phone,
              fee_junior,fee_adult,max_entries,ref_code,format_notes,published,created_at) on public.tournaments to anon;
grant select, insert, update, delete on public.tournaments to authenticated;

-- ---------------------------------------------------------------------
-- 3. Entries (personal data: never public)
-- ---------------------------------------------------------------------
create table if not exists public.tournament_entries (
  id             uuid primary key default gen_random_uuid(),
  tournament_id  uuid not null references public.tournaments(id) on delete cascade,
  member_id      uuid references public.members(id) on delete set null,
  entered_by     uuid,
  title          text check (char_length(title) <= 20),
  category       text not null check (category in ('Female','Open')),
  hand           text not null check (hand in ('LH','RH')),
  agb_no         text check (char_length(agb_no) <= 30),
  surname        text not null check (char_length(surname) between 1 and 80),
  forename       text not null check (char_length(forename) between 1 and 80),
  club           text not null check (char_length(club) between 1 and 100),
  bow_style      text not null check (bow_style in ('Recurve','Compound','Longbow','Barebow')),
  session        text not null check (char_length(session) between 1 and 10),
  special_needs  text check (char_length(special_needs) <= 300),
  dob            date not null,
  age_group      text,
  ianseo_phone   boolean not null default false,
  round_entered  text not null,
  interest_double boolean not null default false,
  drug_consent   boolean not null default false,
  will_score_for_disabled boolean not null default true,
  contact_name   text check (char_length(contact_name) <= 100),
  contact_address text check (char_length(contact_address) <= 300),
  contact_phone  text check (char_length(contact_phone) <= 30),
  contact_email  text check (char_length(contact_email) <= 254),
  fee            numeric(6,2),
  status         text not null default 'requested' check (status in ('requested','confirmed','waitlist','withdrawn')),
  paid           boolean not null default false,
  payment_method text check (char_length(payment_method) <= 60),
  notes          text check (char_length(notes) <= 500),
  created_at     timestamptz not null default now()
);
create index if not exists tournament_entries_t_idx on public.tournament_entries(tournament_id);
create unique index if not exists tournament_entries_once
  on public.tournament_entries(tournament_id, member_id, round_entered)
  where member_id is not null and status <> 'withdrawn';
alter table public.tournament_entries enable row level security;

drop policy if exists te_read      on public.tournament_entries;
drop policy if exists te_committee on public.tournament_entries;
drop policy if exists te_aal2i     on public.tournament_entries;
drop policy if exists te_aal2u     on public.tournament_entries;
drop policy if exists te_aal2d     on public.tournament_entries;
create policy te_read on public.tournament_entries for select to authenticated
  using (public.is_committee() or entered_by = auth.uid() or member_id = public.my_member_id()
         or (member_id is not null and public.is_guardian_of(member_id)));
create policy te_committee on public.tournament_entries for all to authenticated
  using (public.is_committee()) with check (public.is_committee());
create policy te_aal2i on public.tournament_entries as restrictive for insert to authenticated with check (public.is_aal2());
create policy te_aal2u on public.tournament_entries as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy te_aal2d on public.tournament_entries as restrictive for delete to authenticated using (public.is_aal2());
revoke all on public.tournament_entries from anon, authenticated;
grant select, insert, update, delete on public.tournament_entries to authenticated;

-- ---------------------------------------------------------------------
-- 4. Helpers
-- ---------------------------------------------------------------------
-- Archery GB age group, from year of birth (age at 1 January of the event year)
create or replace function public.agb_age_group(p_dob date, p_event date)
returns text language sql immutable as $$
  select case
    when a >= 50 then '50+' when a >= 21 then 'Senior' when a >= 18 then 'Under 21'
    when a >= 16 then 'Under 18' when a = 15 then 'Under 16' when a = 14 then 'Under 15'
    when a >= 12 then 'Under 14' else 'Under 12' end
  from (select extract(year from p_event)::int - extract(year from p_dob)::int as a) s;
$$;

-- Places taken (public, count only)
create or replace function public.tournament_places(p_id uuid)
returns table(taken integer, max_entries integer) language sql stable security definer set search_path = public as $$
  select (select count(*)::int from tournament_entries e where e.tournament_id = t.id and e.status in ('requested','confirmed')),
         t.max_entries
    from tournaments t where t.id = p_id and (t.published or public.is_committee());
$$;
grant execute on function public.tournament_places(uuid) to anon, authenticated;

-- Shared validation + insert. p_member may be null only when the committee enters an outside archer.
create or replace function public._insert_entry(p_t uuid, p_member uuid, p_e jsonb, p_by_committee boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  t public.tournaments; m public.members; v_dob date; v_agb text; v_club text; v_age text; v_fee numeric; v_id uuid;
  v_round text := nullif(trim(p_e->>'round_entered'), '');
  v_sess  text := nullif(trim(p_e->>'session'), '');
begin
  select * into t from tournaments where id = p_t;
  if not found then raise exception 'Tournament not found.' using errcode = '22023'; end if;
  if not p_by_committee then
    if not t.published then raise exception 'This tournament is not open for entries.' using errcode = '22023'; end if;
    if t.closing_date is not null and current_date > t.closing_date then
      raise exception 'Entries for this tournament have closed (closing date %).', to_char(t.closing_date,'DD/MM/YYYY') using errcode = '22023';
    end if;
  end if;
  if v_round is null or not (v_round = any(t.rounds)) then raise exception 'Choose one of the rounds on offer.' using errcode = '22023'; end if;
  if v_sess  is null or not (v_sess  = any(t.sessions)) then raise exception 'Choose a session.' using errcode = '22023'; end if;
  if coalesce((p_e->>'drug_consent')::boolean, false) is not true then
    raise exception 'Drug-testing consent must be ticked (a parent or guardian ticks it for a junior).' using errcode = '22023';
  end if;

  if p_member is not null then
    select * into m from members where id = p_member;
    if not found then raise exception 'Archer not found.' using errcode = '22023'; end if;
    v_dob  := m.dob; v_agb := m.archerygbnum;
    v_club := case when m.membertype = 'guest' then coalesce(nullif(m.home_club,''),'Guest') else 'RJD Archers' end;
  else
    v_dob  := nullif(p_e->>'dob','')::date;
    v_club := nullif(trim(p_e->>'club'),'');
  end if;
  if v_dob is null then raise exception 'A date of birth is needed (add it to the member record).' using errcode = '22023'; end if;
  if v_club is null then raise exception 'Club is needed.' using errcode = '22023'; end if;

  v_age := agb_age_group(v_dob, t.event_date);
  v_fee := case when v_age in ('Under 18','Under 16','Under 15','Under 14','Under 12') then t.fee_junior else t.fee_adult end;

  insert into tournament_entries(tournament_id, member_id, entered_by, title, category, hand, agb_no, surname, forename, club,
      bow_style, session, special_needs, dob, age_group, ianseo_phone, round_entered, interest_double, drug_consent,
      will_score_for_disabled, contact_name, contact_address, contact_phone, contact_email, fee)
  values (p_t, p_member, auth.uid(), nullif(trim(p_e->>'title'),''), p_e->>'category', p_e->>'hand',
      coalesce(nullif(trim(p_e->>'agb_no'),''), v_agb), trim(p_e->>'surname'), trim(p_e->>'forename'), v_club,
      p_e->>'bow_style', v_sess, nullif(trim(p_e->>'special_needs'),''), v_dob, v_age,
      coalesce((p_e->>'ianseo_phone')::boolean,false), v_round, coalesce((p_e->>'interest_double')::boolean,false), true,
      coalesce((p_e->>'will_score_for_disabled')::boolean,true),
      nullif(trim(p_e->>'contact_name'),''), nullif(trim(p_e->>'contact_address'),''),
      nullif(trim(p_e->>'contact_phone'),''), nullif(trim(p_e->>'contact_email'),''), v_fee)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public._insert_entry(uuid,uuid,jsonb,boolean) from public, anon, authenticated;

-- Members (and registered guests) enter themselves; parents enter their under-18 child.
create or replace function public.enter_tournament(p_tournament uuid, p_member uuid, p_entry jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare m public.members;
begin
  if auth.uid() is null or not public.is_aal2() then
    raise exception 'Sign in with your 2FA code first.' using errcode = '42501';
  end if;
  select * into m from members where id = p_member;
  if not found or m.membertype not in ('member','guest') then
    raise exception 'Only members and registered guests can enter.' using errcode = '42501';
  end if;
  if p_member is distinct from public.my_member_id() and not public.is_guardian_of(p_member) then
    raise exception 'You can only enter yourself or your own child.' using errcode = '42501';
  end if;
  return public._insert_entry(p_tournament, p_member, p_entry, false);
end $$;
revoke execute on function public.enter_tournament(uuid,uuid,jsonb) from public, anon;
grant  execute on function public.enter_tournament(uuid,uuid,jsonb) to authenticated;

-- Committee/organiser keys in an entry (e.g. from an emailed or photographed form), member or outside archer
create or replace function public.committee_add_entry(p_tournament uuid, p_member uuid, p_entry jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if not public.is_committee() or not public.is_aal2() then
    raise exception 'Committee with 2FA only.' using errcode = '42501';
  end if;
  return public._insert_entry(p_tournament, p_member, p_entry, true);
end $$;
revoke execute on function public.committee_add_entry(uuid,uuid,jsonb) from public, anon;
grant  execute on function public.committee_add_entry(uuid,uuid,jsonb) to authenticated;

-- Withdraw (owner, parent or committee)
create or replace function public.withdraw_tournament_entry(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e public.tournament_entries;
begin
  if auth.uid() is null or not public.is_aal2() then raise exception 'Sign in with your 2FA code first.' using errcode = '42501'; end if;
  select * into e from tournament_entries where id = p_id;
  if not found then raise exception 'Entry not found.' using errcode = '22023'; end if;
  if not (public.is_committee() or e.entered_by = auth.uid() or e.member_id = public.my_member_id()
          or (e.member_id is not null and public.is_guardian_of(e.member_id))) then
    raise exception 'Not your entry.' using errcode = '42501';
  end if;
  update tournament_entries set status = 'withdrawn' where id = p_id;
end $$;
revoke execute on function public.withdraw_tournament_entry(uuid) from public, anon;
grant  execute on function public.withdraw_tournament_entry(uuid) to authenticated;

-- Bank details are shown to signed-in people only
create or replace function public.tournament_payment_info(p_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select payment_info from tournaments where id = p_id and published and auth.uid() is not null;
$$;
revoke execute on function public.tournament_payment_info(uuid) from public, anon;
grant  execute on function public.tournament_payment_info(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. The three 2027 events from the Excel forms (not published until the committee ticks "published")
-- ---------------------------------------------------------------------
insert into public.tournaments(name,event_date,venue,rounds,closing_date,organiser_name,organiser_email,organiser_phone,ref_code,format_notes)
select * from (values
 ('RJD Archers Portsmouth 2027 UKRS', date '2027-01-31', 'Llantrisant Leisure Centre, Southgate Park, Llantrisant, CF72 8DJ',
  array['Portsmouth'], date '2027-01-10', 'Sian Williams', 'rjdarcherstournaments@gmail.com', '07443 473226', 'P',
  E'Session A: kit inspection 09:15, assembly 09:30, sighters 09:45. Session B: kit inspection 13:15, assembly 13:30, sighters 13:45.\n4 archers per boss, shooting in 2 details. Compounds 60cm triple face; all others 60cm full face. Timed 3 arrow ends.\nDoubles will not be considered initially: tick "interested in a double" to register interest.'),
 ('GAA Senior and Junior Indoor Championship 2027 UKRS', date '2027-02-28', 'Llantrisant Leisure Centre, Southgate Park, Llantrisant, CF72 8DJ',
  array['WA 18'], date '2027-02-07', 'Richard Downer', 'rjdarcherstournaments@gmail.com', '07976 960095', 'WA',
  E'Session A: kit inspection 09:15, assembly 09:30, sighters 09:45. Session B: kit inspection 13:15, assembly 13:30, sighters 13:45.\n4 archers per boss, shooting in 2 details. Compounds 40cm triple face; all others 40cm full size face. Timed 3 arrow ends.\nSingle rounds only initially: tick "interested in a double" to register interest.'),
 ('RJD Archers Indoor Vegas and Worcester Championship 2027 UKRS', date '2027-04-04', 'Llantrisant Leisure Centre, Southgate Park, Llantrisant, CF72 8DJ',
  array['Vegas','Worcester'], date '2027-03-14', 'Graham Mansbridge', 'rjdarcherstournaments@gmail.com', '07495 445076', 'V or W',
  E'Vegas in the morning session, Worcester in the afternoon session. Session A: kit inspection 09:15, assembly 09:30, sighters 09:45. Session B: kit inspection 13:15, assembly 13:30, sighters 13:45.\n4 archers per boss, shooting in 2 details. Compounds Worcester 5 spot; all others Worcester full face. Timed 5 arrow ends.\nSingle rounds only initially: tick "interested in a double" to register interest.')
) v(name,event_date,venue,rounds,closing_date,organiser_name,organiser_email,organiser_phone,ref_code,format_notes)
where not exists (select 1 from public.tournaments t where t.name = v.name);

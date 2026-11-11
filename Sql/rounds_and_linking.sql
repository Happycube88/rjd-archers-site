-- RJD Archers: (1) link members to their login automatically, (2) rounds list for dropdowns,
-- (3) record keeper's list of 252 entries awaiting verification.
-- Run once, as one run, in the Supabase SQL editor. Safe to run again.
begin;

-- ---------------------------------------------------------------------
-- 1. AUTO-LINK: a member row is tied to a login by CONFIRMED email.
--    Works in both orders: person signs in first, or committee adds them first.
-- ---------------------------------------------------------------------
create or replace function public.link_member_to_login()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.email is not null and new.email_confirmed_at is not null then
    update public.members set auth_id = new.id
     where auth_id is null and lower(email) = lower(new.email);
  end if;
  return new;
end $$;

drop trigger if exists link_member_on_login on auth.users;
create trigger link_member_on_login
  after insert or update of email_confirmed_at, email on auth.users
  for each row execute function public.link_member_to_login();

create or replace function public.members_autolink()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.auth_id is null and new.email is not null then
    select u.id into new.auth_id from auth.users u
     where lower(u.email) = lower(new.email) and u.email_confirmed_at is not null limit 1;
  end if;
  return new;
end $$;

drop trigger if exists members_autolink on public.members;
create trigger members_autolink
  before insert or update of email on public.members
  for each row execute function public.members_autolink();

revoke execute on function public.link_member_to_login(), public.members_autolink() from public, anon, authenticated;

-- link anyone already waiting
update public.members m set auth_id = u.id
  from auth.users u
 where m.auth_id is null and u.email_confirmed_at is not null and lower(u.email) = lower(m.email);

-- ---------------------------------------------------------------------
-- 2. ROUNDS LIST (feeds the dropdowns). Record keeper can add/edit; everyone can read.
-- ---------------------------------------------------------------------
create table if not exists public.rounds (
  id          bigint generated always as identity primary key,
  name        text not null unique check (char_length(name) between 1 and 60),
  environment text not null default 'indoor' check (environment in ('indoor','outdoor')),
  sort        integer not null default 100,
  active      boolean not null default true
);
alter table public.rounds enable row level security;

drop policy if exists "rounds public read" on public.rounds;
drop policy if exists "rk insert rounds"   on public.rounds;
drop policy if exists "rk update rounds"   on public.rounds;
drop policy if exists "rk delete rounds"   on public.rounds;
drop policy if exists "aal2 rounds insert" on public.rounds;
drop policy if exists "aal2 rounds update" on public.rounds;
drop policy if exists "aal2 rounds delete" on public.rounds;
create policy "rounds public read" on public.rounds for select to anon, authenticated using (true);
create policy "rk insert rounds"   on public.rounds for insert to authenticated with check (public.is_recordkeeper());
create policy "rk update rounds"   on public.rounds for update to authenticated using (public.is_recordkeeper()) with check (public.is_recordkeeper());
create policy "rk delete rounds"   on public.rounds for delete to authenticated using (public.is_recordkeeper());
create policy "aal2 rounds insert" on public.rounds as restrictive for insert to authenticated with check (public.is_aal2());
create policy "aal2 rounds update" on public.rounds as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy "aal2 rounds delete" on public.rounds as restrictive for delete to authenticated using (public.is_aal2());

revoke all on public.rounds from anon, authenticated;
grant select on public.rounds to anon;
grant select, insert, update, delete on public.rounds to authenticated;

-- the 17 indoor rounds in the Glamorgan list, plus a few common outdoor ones (edit freely on the site)
insert into public.rounds (name, environment, sort) values
  ('Bray I','indoor',10), ('Bray I Double','indoor',11), ('Bray II','indoor',12), ('Bray II Double','indoor',13),
  ('Portsmouth','indoor',20), ('Portsmouth Double','indoor',21), ('Portsmouth Triple','indoor',22),
  ('Stafford','indoor',30), ('Worcester','indoor',40), ('Worcester Double','indoor',41),
  ('Vegas (300)','indoor',50), ('Vegas (Triple Face)','indoor',51),
  ('WA 18m','indoor',60), ('WA 18m Double','indoor',61), ('WA 25m','indoor',62), ('WA 25m Double','indoor',63),
  ('WA 25/18m Comb''d','indoor',64),
  ('York','outdoor',10), ('Hereford','outdoor',11), ('St George','outdoor',12), ('Albion','outdoor',13),
  ('Windsor','outdoor',14), ('Western','outdoor',15), ('American','outdoor',16), ('National','outdoor',17)
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- 3. RECORD KEEPER: list of 252 entries (with member names) to verify
-- ---------------------------------------------------------------------
create or replace function public.list_252_for_keeper()
returns table (id bigint, member_name text, shoot_date date, round text, bow_style text,
               score integer, stage text, verified boolean)
language sql stable security definer set search_path = public as $$
  select p.id, m.name, p.shoot_date, p.round, p.bow_style, p.score, p.stage, p.verified
    from public.member_252_progress p
    join public.members m on m.id = p.member_id
   where public.is_recordkeeper()
   order by p.verified, p.shoot_date desc, p.id desc
   limit 300;
$$;
revoke execute on function public.list_252_for_keeper() from public, anon;
grant  execute on function public.list_252_for_keeper() to authenticated;

commit;

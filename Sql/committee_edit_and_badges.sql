-- RJD Archers: committee editing safeguards, parents on 252 scores, and "badge awarded" tracking.
-- Run once in the Supabase SQL editor AFTER members_family.sql and badge_252.sql. Safe to run again.
begin;

-- ---------------------------------------------------------------------
-- 1. Safeguards for the committee edit screen
--    (a) there must always be at least one committee member
--    (b) an under-18 must always keep at least one parent or guardian
--    Both are checked when the change is saved. The SQL editor is exempt, so you can always fix things.
-- ---------------------------------------------------------------------
create or replace function public.check_one_committee_left()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;
  if not exists (select 1 from public.members
                  where tournamentscom or membershipcom or welfarecom or secretarycom or chaircom) then
    raise exception 'There must always be at least one committee member. Give the role to someone else first.'
      using errcode = '23514';
  end if;
  return null;
end $$;
drop trigger if exists keep_one_committee on public.members;
create constraint trigger keep_one_committee
  after update or delete on public.members
  deferrable initially deferred for each row
  when (old.tournamentscom or old.membershipcom or old.welfarecom or old.secretarycom or old.chaircom)
  execute function public.check_one_committee_left();

create or replace function public.check_child_keeps_guardian()
returns trigger language plpgsql security definer set search_path = public as $$
declare d date;
begin
  if auth.uid() is null then return null; end if;
  select dob into d from public.members where id = old.child_id;
  if found and d is not null and d > current_date - interval '18 years'
     and not exists (select 1 from public.member_guardians where child_id = old.child_id) then
    raise exception 'A member under 18 must keep at least one parent or guardian.' using errcode = '23514';
  end if;
  return null;
end $$;
drop trigger if exists child_keeps_guardian on public.member_guardians;
revoke execute on function public.check_one_committee_left(), public.check_child_keeps_guardian() from public, anon, authenticated;
create constraint trigger child_keeps_guardian
  after delete on public.member_guardians
  deferrable initially deferred for each row execute function public.check_child_keeps_guardian();

-- ---------------------------------------------------------------------
-- 2. Parents and guardians can see and add 252 scores for their under-18 child
--    (still unverified until the record keeper checks them; 2FA still required)
-- ---------------------------------------------------------------------
drop policy if exists "252 read"   on public.member_252_progress;
drop policy if exists "252 insert" on public.member_252_progress;
create policy "252 read" on public.member_252_progress for select to authenticated
  using (member_id = public.my_member_id() or public.is_guardian_of(member_id)
         or public.is_recordkeeper() or public.is_committee());
create policy "252 insert" on public.member_252_progress for insert to authenticated
  with check (((member_id = public.my_member_id() or public.is_guardian_of(member_id)) and verified = false)
              or public.is_recordkeeper());

-- ---------------------------------------------------------------------
-- 3. Badges: earned (two verified scores) -> awarded (badge handed over)
-- ---------------------------------------------------------------------
create table if not exists public.badge_252_awards (
  member_id    uuid not null references public.members(id) on delete cascade,
  bow_style    text not null,
  distance_yds integer not null,
  awarded_on   date not null default current_date,
  awarded_by   uuid references public.members(id) on delete set null,
  note         text check (char_length(note) <= 120),
  primary key (member_id, bow_style, distance_yds)
);
alter table public.badge_252_awards enable row level security;
drop policy if exists "badge awards read" on public.badge_252_awards;
create policy "badge awards read" on public.badge_252_awards for select to authenticated
  using (public.is_recordkeeper() or public.is_committee()
         or member_id = public.my_member_id() or public.is_guardian_of(member_id));
revoke all on public.badge_252_awards from anon, authenticated;
grant select on public.badge_252_awards to authenticated;   -- changes only through the function below

drop function if exists public.list_252_badges_for_keeper();
create function public.list_252_badges_for_keeper()
returns table (member_id uuid, member_name text, bow_style text, distance_yds integer,
               qualifying_scores integer, earned_on date, awarded_on date, awarded_note text)
language sql stable security definer set search_path = public as $$
  with q as (
    select p.member_id, t.bow_style, p.distance_yds, p.shoot_date,
           row_number() over (partition by p.member_id, t.bow_style, p.distance_yds order by p.shoot_date, p.id) rn,
           count(*)     over (partition by p.member_id, t.bow_style, p.distance_yds) n
      from public.member_252_progress p
      join public.badge_252_thresholds t
        on lower(t.bow_style) = lower(p.bow_style) and t.distance_yds = p.distance_yds
     where p.verified and p.score >= t.min_score
  )
  select q.member_id, m.name, q.bow_style, q.distance_yds, q.n::int, q.shoot_date, a.awarded_on, a.note
    from q join public.members m on m.id = q.member_id
    left join public.badge_252_awards a
           on a.member_id = q.member_id and a.bow_style = q.bow_style and a.distance_yds = q.distance_yds
   where public.is_recordkeeper() and q.rn = 2
   order by (a.awarded_on is not null), q.shoot_date desc, m.name;
$$;
revoke execute on function public.list_252_badges_for_keeper() from public, anon;
grant  execute on function public.list_252_badges_for_keeper() to authenticated;

create or replace function public.keeper_set_badge_award(p_member uuid, p_bow text, p_dist integer,
                                                         p_awarded boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_bow text;
begin
  if not public.is_recordkeeper() or not public.is_aal2() then
    raise exception 'Record keeper with 2FA only.' using errcode = '42501';
  end if;
  select t.bow_style into v_bow from public.badge_252_thresholds t
   where lower(t.bow_style) = lower(p_bow) and t.distance_yds = p_dist;
  if v_bow is null then raise exception 'Unknown bow type or distance.'; end if;
  if p_awarded then
    if (select count(*) from public.member_252_progress p
         join public.badge_252_thresholds t on lower(t.bow_style) = lower(p.bow_style) and t.distance_yds = p.distance_yds
        where p.member_id = p_member and t.bow_style = v_bow and p.distance_yds = p_dist
          and p.verified and p.score >= t.min_score) < 2 then
      raise exception 'That badge has not been earned yet: it needs two verified scores at the target.';
    end if;
    insert into public.badge_252_awards (member_id, bow_style, distance_yds, awarded_by, note)
    values (p_member, v_bow, p_dist, public.my_member_id(), nullif(trim(p_note), ''))
    on conflict (member_id, bow_style, distance_yds) do update set note = excluded.note;
  else
    delete from public.badge_252_awards where member_id = p_member and bow_style = v_bow and distance_yds = p_dist;
  end if;
end $$;
revoke execute on function public.keeper_set_badge_award(uuid, text, integer, boolean, text) from public, anon;
grant  execute on function public.keeper_set_badge_award(uuid, text, integer, boolean, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Committee: link another parent or guardian to an existing child (one safe step)
-- ---------------------------------------------------------------------
create or replace function public.committee_add_guardian(p_child uuid, p_guardian jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_gid uuid; v_email text;
begin
  if not public.is_committee() or not public.is_aal2() then
    raise exception 'Committee with 2FA only.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.members where id = p_child) then raise exception 'That child was not found.'; end if;
  v_gid := nullif(p_guardian->>'member_id','')::uuid;
  if v_gid is null then
    v_email := nullif(lower(trim(p_guardian->>'email')),'');
    if coalesce(trim(p_guardian->>'name'),'') = '' or v_email is null then
      raise exception 'A new parent or guardian needs a name and an email (they sign in with it).';
    end if;
    select id into v_gid from public.members where lower(email) = v_email;
    if v_gid is null then
      insert into public.members (name, email, mobile, membertype)
      values (trim(p_guardian->>'name'), v_email, nullif(trim(p_guardian->>'mobile'),''), 'parent') returning id into v_gid;
    end if;
  end if;
  if v_gid = p_child then raise exception 'A person cannot be their own guardian.'; end if;
  insert into public.member_guardians (child_id, guardian_member_id, relationship)
  values (p_child, v_gid, nullif(trim(p_guardian->>'relationship'),''))
  on conflict (child_id, guardian_member_id) do update set relationship = excluded.relationship;
  return v_gid;
end $$;
revoke execute on function public.committee_add_guardian(uuid, jsonb) from public, anon;
grant  execute on function public.committee_add_guardian(uuid, jsonb) to authenticated;

commit;

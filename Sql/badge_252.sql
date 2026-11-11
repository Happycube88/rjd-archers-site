-- RJD Archers: 252 Outdoor Round badge rules (from "The 252 Outdoor Round" sheet).
-- Run once in the Supabase SQL editor. Safe to run again.
begin;

-- 1. Distance on each 252 entry, and sanity limits (36 arrows x 9 = 324 max)
alter table public.member_252_progress add column if not exists distance_yds integer;
alter table public.member_252_progress drop constraint if exists m252_distance_ck;
alter table public.member_252_progress add constraint m252_distance_ck
  check (distance_yds is null or distance_yds in (20,30,40,50,60,80,100));
alter table public.member_252_progress drop constraint if exists m252_score_max_ck;
alter table public.member_252_progress add constraint m252_score_max_ck
  check (score is null or score <= 324) not valid;

-- tidy the early test entry (round "20yrds", bow "recurve") into the new shape
update public.member_252_progress
   set distance_yds = (regexp_match(round, '^(20|30|40|50|60|80|100)\s*y', 'i'))[1]::int
 where distance_yds is null and round ~* '^(20|30|40|50|60|80|100)\s*y';
update public.member_252_progress set bow_style = initcap(bow_style)
 where bow_style is not null and lower(bow_style) in ('recurve','compound','longbow','barebow');

-- 2. Qualifying scores: 36 arrows at one distance
create table if not exists public.badge_252_thresholds (
  bow_style    text    not null check (bow_style in ('Recurve','Compound','Longbow','Barebow')),
  distance_yds integer not null check (distance_yds in (20,30,40,50,60,80,100)),
  min_score    integer not null check (min_score between 1 and 324),
  primary key (bow_style, distance_yds)
);
alter table public.badge_252_thresholds enable row level security;
drop policy if exists "252 thresholds public read" on public.badge_252_thresholds;
create policy "252 thresholds public read" on public.badge_252_thresholds
  for select to anon, authenticated using (true);
revoke all on public.badge_252_thresholds from anon, authenticated;
grant select on public.badge_252_thresholds to anon, authenticated;

insert into public.badge_252_thresholds (bow_style, distance_yds, min_score)
select b.bow, d.dist,
       case b.bow
         when 'Recurve'  then 252
         when 'Compound' then 280
         when 'Longbow'  then case when d.dist <= 60 then 164 when d.dist = 80 then 126 else 101 end
         when 'Barebow'  then case when d.dist <= 60 then 189 when d.dist = 80 then 164 else 139 end
       end
  from (values ('Recurve'),('Compound'),('Longbow'),('Barebow')) b(bow)
 cross join (values (20),(30),(40),(50),(60),(80),(100)) d(dist)
on conflict (bow_style, distance_yds) do update set min_score = excluded.min_score;

-- 3. Record keeper: list of entries, saying whether each one qualifies
drop function if exists public.list_252_for_keeper();
create function public.list_252_for_keeper()
returns table (id bigint, member_name text, shoot_date date, round text, bow_style text,
               distance_yds integer, score integer, notes text, verified boolean,
               min_score integer, qualifies boolean, badge_earned boolean)
language sql stable security definer set search_path = public as $$
  with e as (
    select p.*, t.min_score,
           (t.min_score is not null and p.score >= t.min_score) as q
      from public.member_252_progress p
      left join public.badge_252_thresholds t
        on lower(t.bow_style) = lower(p.bow_style) and t.distance_yds = p.distance_yds
  )
  select e.id, m.name, e.shoot_date, e.round, e.bow_style, e.distance_yds, e.score, e.notes, e.verified,
         e.min_score, e.q,
         (select count(*) from e e2
           where e2.member_id = e.member_id and lower(e2.bow_style) = lower(e.bow_style)
             and e2.distance_yds = e.distance_yds and e2.verified and e2.q) >= 2
    from e join public.members m on m.id = e.member_id
   where public.is_recordkeeper()
   order by e.verified, e.shoot_date desc, e.id desc
   limit 300;
$$;
revoke execute on function public.list_252_for_keeper() from public, anon;
grant  execute on function public.list_252_for_keeper() to authenticated;

-- 4. Record keeper: badges earned (two VERIFIED qualifying scores at the same distance and bow)
create or replace function public.list_252_badges_for_keeper()
returns table (member_name text, bow_style text, distance_yds integer, qualifying_scores integer, earned_on date)
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
  select m.name, q.bow_style, q.distance_yds, q.n::int, q.shoot_date
    from q join public.members m on m.id = q.member_id
   where public.is_recordkeeper() and q.rn = 2
   order by q.shoot_date desc, m.name;
$$;
revoke execute on function public.list_252_badges_for_keeper() from public, anon;
grant  execute on function public.list_252_badges_for_keeper() to authenticated;

-- 5. PUBLIC: top 252 badge scores (club records). Only VERIFIED, qualifying scores.
--    Under-18s, and anyone without a date of birth on file, show as "First S." only.
create or replace function public.top_252_scores()
returns table (bow_style text, distance_yds integer, score integer, shoot_date date, archer text)
language sql stable security definer set search_path = public as $$
  select distinct on (t.bow_style, p.distance_yds)
         t.bow_style, p.distance_yds, p.score, p.shoot_date,
         case when m.dob is not null and m.dob <= (current_date - interval '18 years')
              then m.name
              when position(' ' in trim(m.name)) > 0
              then split_part(trim(m.name), ' ', 1) || ' ' || left((regexp_match(trim(m.name), '(\S+)$'))[1], 1) || '.'
              else trim(m.name)
         end
    from public.member_252_progress p
    join public.badge_252_thresholds t
      on lower(t.bow_style) = lower(p.bow_style) and t.distance_yds = p.distance_yds
    join public.members m on m.id = p.member_id
   where p.verified and p.score >= t.min_score
   order by t.bow_style, p.distance_yds, p.score desc, p.shoot_date, p.id;
$$;
revoke execute on function public.top_252_scores() from public;
grant  execute on function public.top_252_scores() to anon, authenticated;

commit;

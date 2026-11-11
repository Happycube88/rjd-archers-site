-- Security check. Run the WHOLE file in the Supabase SQL editor - nothing to edit.
-- It tests the live rules as a stranger, the public, a committee member and a record keeper,
-- then undoes everything. Result: a table of PASS / FAIL (and SKIPPED where nobody exists yet).
-- Any FAIL = send me the table.

create or replace function pg_temp.t(r text, sub text, aal text, stmt text, expect text)
returns text language plpgsql as $$
declare n bigint; res text; det text := '';
begin
  perform set_config('request.jwt.claims',
          json_build_object('sub', nullif(sub,''), 'role', r, 'aal', aal)::text, true);
  execute format('set local role %I', r);
  begin
    execute stmt;
    get diagnostics n = row_count;
    res := case when n > 0 then 'rows' else 'zero' end;
    raise exception 'undo';                       -- always undo any change the test made
  exception
    when insufficient_privilege then res := 'denied'; det := sqlerrm;
    when raise_exception then
      if sqlerrm <> 'undo' then res := 'error'; det := sqlerrm; end if;
    when others then res := 'error'; det := sqlerrm;
  end;
  reset role;
  return case when expect = 'any' and res in ('rows','zero') then 'PASS'
              when expect = 'blocked' and res in ('denied','error') then 'PASS'
              when res = expect then 'PASS'
              else 'FAIL (got ' || res || ', wanted ' || expect || ')' || case when det <> '' then ' - DB said: ' || det else '' end end;
end $$;

with who as (
  select
    '00000000-0000-0000-0000-00000000dead'::text as stranger,
    (select auth_id::text from public.members where auth_id is not null
        and (coalesce(chaircom,false) or coalesce(secretarycom,false) or coalesce(membershipcom,false)
          or coalesce(welfarecom,false) or coalesce(tournamentscom,false)) limit 1) as committee,
    (select auth_id::text from public.members where auth_id is not null and recordkeeper limit 1) as keeper,
    (select auth_id::text from public.members where auth_id is not null
        and not (coalesce(chaircom,false) or coalesce(secretarycom,false) or coalesce(membershipcom,false)
              or coalesce(welfarecom,false) or coalesce(tournamentscom,false) or recordkeeper) limit 1) as plain
)
select n, test, result from (
  select 1 as n, 'A committee member exists and is linked to a login' as test,
         case when committee is not null then 'PASS' else 'FAIL - run bootstrap_first_committee.sql' end as result from who
  union all select 2, 'A record keeper exists and is linked to a login',
         case when keeper is not null then 'PASS' else 'FAIL - run bootstrap_first_committee.sql' end from who
  union all select 10, 'Public cannot read members',
         pg_temp.t('anon','','aal1','select 1 from public.members','denied') from who
  union all select 11, 'Public cannot read enquiries',
         pg_temp.t('anon','','aal1','select 1 from public.enquiries','denied') from who
  union all select 12, 'Public can send a beginner enquiry',
         pg_temp.t('anon','','aal1',$q$insert into public.enquiries (name,email) values ('Verify Test','verify@example.com')$q$,'rows') from who
  union all select 13, 'Public cannot create a member row',
         pg_temp.t('anon','','aal1',$q$insert into public.members (name,email,membertype) values ('x','x@example.com','beginner')$q$,'denied') from who
  union all select 14, 'Public can read records',
         pg_temp.t('anon','','aal1','select 1 from public.records','any') from who
  union all select 15, 'Public cannot add a record',
         pg_temp.t('anon','','aal1',$q$insert into public.records (round,bow_style,class,score,archer_name) values ('T','T','T',1,'T')$q$,'denied') from who
  union all select 20, 'Stranger with 2FA cannot make themselves committee (insert)',
         pg_temp.t('authenticated', stranger,'aal2',
           format($q$insert into public.members (name,email,chaircom,membertype,auth_id) values ('x','hack@example.com',true,'beginner','%s')$q$, stranger),'blocked') from who
  union all select 21, 'Stranger sees no members',
         pg_temp.t('authenticated', stranger,'aal2','select 1 from public.members','zero') from who
  union all select 22, 'Stranger sees no enquiries',
         pg_temp.t('authenticated', stranger,'aal2','select 1 from public.enquiries','zero') from who
  union all select 23, 'Stranger cannot add a record',
         pg_temp.t('authenticated', stranger,'aal2',$q$insert into public.records (round,bow_style,class,score,archer_name) values ('T','T','T',1,'T')$q$,'denied') from who
  union all select 30, 'Committee can read all members (no 2FA needed to read)',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal1','select 1 from public.members','rows') end from who
  union all select 31, 'Committee edit WITHOUT 2FA is blocked',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal1',format($q$update public.members set mobile = mobile where auth_id = '%s'$q$, committee),'zero') end from who
  union all select 32, 'Committee edit WITH 2FA works',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal2',format($q$update public.members set mobile = mobile where auth_id = '%s'$q$, committee),'rows') end from who
  union all select 33, 'Committee can read enquiries',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal1','select 1 from public.enquiries','any') end from who
  union all select 40, 'Record keeper adding a record WITHOUT 2FA is blocked',
         case when keeper is null then 'SKIPPED'
              else pg_temp.t('authenticated', keeper,'aal1',$q$insert into public.records (round,bow_style,class,score,archer_name) values ('T','T','T',1,'T')$q$,'denied') end from who
  union all select 41, 'Record keeper adding a record WITH 2FA works',
         case when keeper is null then 'SKIPPED'
              else pg_temp.t('authenticated', keeper,'aal2',$q$insert into public.records (round,bow_style,class,score,archer_name) values ('T','T','T',1,'T')$q$,'rows') end from who
  union all select 50, 'Ordinary member cannot promote themselves to committee',
         case when plain is null then 'SKIPPED (no ordinary member has signed in yet)'
              else pg_temp.t('authenticated', plain,'aal2',format($q$update public.members set secretarycom = true where auth_id = '%s'$q$, plain),'denied') end from who
  union all select 51, 'Ordinary member can edit their own mobile (with 2FA)',
         case when plain is null then 'SKIPPED (no ordinary member has signed in yet)'
              else pg_temp.t('authenticated', plain,'aal2',format($q$update public.members set mobile = mobile where auth_id = '%s'$q$, plain),'rows') end from who
  union all select 52, 'Ordinary member cannot read other members',
         case when plain is null then 'SKIPPED (no ordinary member has signed in yet)'
              else pg_temp.t('authenticated', plain,'aal2',format($q$select 1 from public.members where auth_id <> '%s'$q$, plain),'zero') end from who
  union all select 70, 'Public can read the rounds list',
         pg_temp.t('anon','','aal1','select 1 from public.rounds','any') from who
  union all select 71, 'Public cannot add a round',
         pg_temp.t('anon','','aal1',$q$insert into public.rounds (name) values ('Hack')$q$,'denied') from who
  union all select 72, 'Record keeper can add a round with 2FA',
         case when keeper is null then 'SKIPPED'
              else pg_temp.t('authenticated', keeper,'aal2',$q$insert into public.rounds (name) values ('Verify Test Round')$q$,'rows') end from who
  union all select 73, 'Record keeper cannot add a round without 2FA',
         case when keeper is null then 'SKIPPED'
              else pg_temp.t('authenticated', keeper,'aal1',$q$insert into public.rounds (name) values ('Verify Test Round')$q$,'denied') end from who
  union all select 74, 'Stranger gets nothing from the 252 verification list',
         pg_temp.t('authenticated', stranger,'aal2','select * from public.list_252_for_keeper()','zero') from who
  union all select 75, 'Record keeper can open the 252 verification list',
         case when keeper is null then 'SKIPPED'
              else pg_temp.t('authenticated', keeper,'aal1','select * from public.list_252_for_keeper()','any') end from who
  union all select 80, 'Public can read the 252 badge targets',
         pg_temp.t('anon','','aal1','select 1 from public.badge_252_thresholds','any') from who
  union all select 81, 'Public cannot change the 252 badge targets',
         pg_temp.t('anon','','aal1','update public.badge_252_thresholds set min_score = 1','denied') from who
  union all select 82, 'Public can see the top 252 badge scores',
         pg_temp.t('anon','','aal1','select * from public.top_252_scores()','any') from who
  union all select 83, 'Public cannot read members 252 entries directly',
         pg_temp.t('anon','','aal1','select 1 from public.member_252_progress','denied') from who
  union all select 84, 'Stranger gets nothing from the badges-earned list',
         pg_temp.t('authenticated', stranger,'aal2','select * from public.list_252_badges_for_keeper()','zero') from who
  union all select 85, 'Record keeper can open the badges-earned list',
         case when keeper is null then 'SKIPPED'
              else pg_temp.t('authenticated', keeper,'aal1','select * from public.list_252_badges_for_keeper()','any') end from who
  union all select 90, 'Public cannot read parent/guardian links',
         pg_temp.t('anon','','aal1','select 1 from public.member_guardians','denied') from who
  union all select 91, 'Stranger sees no parent/guardian links',
         pg_temp.t('authenticated', stranger,'aal2','select 1 from public.member_guardians','zero') from who
  union all select 92, 'Stranger cannot add a member through the committee tool',
         pg_temp.t('authenticated', stranger,'aal2',$q$select public.committee_add_member('{"name":"Verify Adult","email":"verify-adult@example.com","dob":"1985-03-03","next_of_kin_name":"A","next_of_kin_phone":"1"}'::jsonb)$q$,'denied') from who
  union all select 93, 'Committee without 2FA cannot add a member',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal1',$q$select public.committee_add_member('{"name":"Verify Adult","email":"verify-adult@example.com","dob":"1985-03-03","next_of_kin_name":"A","next_of_kin_phone":"1"}'::jsonb)$q$,'denied') end from who
  union all select 94, 'Committee with 2FA can add an adult beginner (with next of kin)',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal2',$q$select public.committee_add_member('{"name":"Verify Adult","email":"verify-adult@example.com","dob":"1985-03-03","next_of_kin_name":"A","next_of_kin_phone":"1"}'::jsonb)$q$,'rows') end from who
  union all select 95, 'Adding a member without next of kin is refused',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal2',$q$select public.committee_add_member('{"name":"No Kin","email":"nokin@example.com","dob":"1985-03-03"}'::jsonb)$q$,'error') end from who
  union all select 96, 'Under-18 without a parent or guardian is refused',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal2',$q$select public.committee_add_member('{"name":"Junior Test","dob":"2014-01-01","next_of_kin_name":"A","next_of_kin_phone":"1"}'::jsonb)$q$,'error') end from who
  union all select 97, 'Under-18 with a new parent is accepted',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal2',$q$select public.committee_add_member('{"name":"Junior Test","dob":"2014-01-01","next_of_kin_name":"A","next_of_kin_phone":"1"}'::jsonb,'[{"name":"Parent Test","email":"parent-test@example.com"}]'::jsonb)$q$,'rows') end from who
  union all select 98, 'Making someone a member without course proof is refused',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal2',$q$select public.committee_add_member('{"name":"Member Test","email":"member-test@example.com","dob":"1985-03-03","membertype":"member","next_of_kin_name":"A","next_of_kin_phone":"1"}'::jsonb)$q$,'error') end from who
  union all select 99, 'Ordinary member cannot use the make-member tool',
         case when plain is null then 'SKIPPED (no ordinary member has signed in yet)'
              else pg_temp.t('authenticated', plain,'aal2',$q$select public.committee_make_member(gen_random_uuid(),'club')$q$,'denied') end from who
  union all select 100, 'Public cannot read badge awards',
         pg_temp.t('anon','','aal1','select 1 from public.badge_252_awards','denied') from who
  union all select 101, 'Stranger sees no badge awards',
         pg_temp.t('authenticated', stranger,'aal2','select 1 from public.badge_252_awards','zero') from who
  union all select 102, 'Stranger cannot mark a badge awarded',
         pg_temp.t('authenticated', stranger,'aal2',$q$select public.keeper_set_badge_award(gen_random_uuid(),'Recurve',30,true)$q$,'denied') from who
  union all select 103, 'Record keeper without 2FA cannot mark a badge awarded',
         case when keeper is null then 'SKIPPED'
              else pg_temp.t('authenticated', keeper,'aal1',$q$select public.keeper_set_badge_award(gen_random_uuid(),'Recurve',30,true)$q$,'denied') end from who
  union all select 110, 'Registered guest without next of kin is refused',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal2',$q$select public.committee_add_member('{"name":"Guest Test","email":"guest-test@example.com","dob":"1985-03-03","membertype":"guest","home_club":"Castle Bowmen"}'::jsonb)$q$,'error') end from who
  union all select 111, 'Registered guest with next of kin needs no course proof',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal2',$q$select public.committee_add_member('{"name":"Guest Test","email":"guest-test@example.com","dob":"1985-03-03","membertype":"guest","home_club":"Castle Bowmen","next_of_kin_name":"A","next_of_kin_phone":"1"}'::jsonb)$q$,'rows') end from who
  union all select 112, 'Public cannot read one-off shoot guests',
         pg_temp.t('anon','','aal1','select 1 from public.shoot_guests','denied') from who
  union all select 113, 'Stranger sees no one-off shoot guests',
         pg_temp.t('authenticated', stranger,'aal2','select 1 from public.shoot_guests','zero') from who
  union all select 114, 'Committee without 2FA cannot add a one-off guest',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal1',$q$insert into public.shoot_guests(name,shoot_date) values ('X', current_date)$q$,'denied') end from who
  union all select 115, 'Public cannot read tournament entries',
         pg_temp.t('anon','','aal1','select 1 from public.tournament_entries','denied') from who
  union all select 116, 'Stranger sees no tournament entries',
         pg_temp.t('authenticated', stranger,'aal2','select 1 from public.tournament_entries','zero') from who
  union all select 117, 'Public cannot read tournament bank details',
         pg_temp.t('anon','','aal1','select payment_info from public.tournaments','denied') from who
  union all select 118, 'Stranger cannot use the committee entry tool',
         pg_temp.t('authenticated', stranger,'aal2',$q$select public.committee_add_entry(gen_random_uuid(), null, '{}'::jsonb)$q$,'denied') from who
  union all select 119, 'Stranger cannot enter a tournament as someone else',
         pg_temp.t('authenticated', stranger,'aal2',$q$select public.enter_tournament(gen_random_uuid(), gen_random_uuid(), '{}'::jsonb)$q$,'denied') from who
  union all select 120, 'Committee without 2FA cannot change a tournament',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal1',$q$update public.tournaments set name = name$q$,'zero') end from who
  union all select 121, 'Public cannot read club night bookings',
         pg_temp.t('anon','','aal1','select 1 from public.club_night_bookings','denied') from who
  union all select 122, 'Stranger sees no club night bookings',
         pg_temp.t('authenticated', stranger,'aal2','select 1 from public.club_night_bookings','zero') from who
  union all select 123, 'Stranger cannot see a club night attendee list',
         pg_temp.t('authenticated', stranger,'aal2',$q$select * from public.club_night_attendees(gen_random_uuid())$q$,'denied') from who
  union all select 124, 'Stranger cannot create a club night',
         pg_temp.t('authenticated', stranger,'aal2',$q$insert into public.club_nights(night_date,kind,range_distance,range_unit) values (current_date,'outdoor',50,'metres')$q$,'denied') from who
  union all select 125, 'Committee without 2FA cannot create a club night',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal1',$q$insert into public.club_nights(night_date,kind,range_distance,range_unit) values (current_date,'outdoor',50,'metres')$q$,'denied') end from who
  union all select 126, 'Indoor club night over 26 people is refused',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal2',$q$insert into public.club_nights(night_date,kind,range_distance,range_unit,target_size,target_type,max_places) values (current_date,'indoor',18,'yards','40cm','Full',27)$q$,'error') end from who
  union all select 127, 'Stranger cannot mark a booking paid',
         pg_temp.t('authenticated', stranger,'aal2',$q$select public.committee_set_booking_paid(gen_random_uuid(), true)$q$,'denied') from who
  union all select 128, 'Stranger cannot read the club night pattern and defaults',
         pg_temp.t('authenticated', stranger,'aal2','select 1 from public.club_night_defaults','zero') from who
  union all select 129, 'Stranger cannot run the club night generator',
         pg_temp.t('authenticated', stranger,'aal2','select public.generate_club_nights(4)','denied') from who
  union all select 130, 'Committee without 2FA cannot run the club night generator',
         case when committee is null then 'SKIPPED'
              else pg_temp.t('authenticated', committee,'aal1','select public.generate_club_nights(4)','denied') end from who
  union all select 131, 'Public cannot change the club night pattern',
         pg_temp.t('anon','','aal1','update public.club_night_rules set active = active','denied') from who
  union all select 60, 'Public has no direct rights on members table',
         case when has_table_privilege('anon','public.members','select,insert,update,delete') then 'FAIL' else 'PASS' end from who
  union all select 61, 'Every table in the public schema has row-level security on',
         coalesce((select 'FAIL - missing on: ' || string_agg(relname, ', ') from pg_class
                    where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity), 'PASS') from who
) x order by n;

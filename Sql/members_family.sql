-- RJD Archers: next of kin, fee category, course proof, parents/guardians, committee add-member tools.
-- Run once in the Supabase SQL editor. Safe to run again.
--
-- Stages a person moves through:
--   enquiry (public form, enquiries table)  ->  beginner (committee adds them when they pay for the course)
--   ->  member (only once course proof is recorded: done with the club or elsewhere)
-- Parents/guardians who are not archers are stored as members with membertype 'parent' so they get a
-- login (for booking, and for updating their child's details). One parent can be linked to several children.
begin;

-- ---------------------------------------------------------------------
-- 1. New columns on members
-- ---------------------------------------------------------------------
alter table public.members add column if not exists next_of_kin_name  text;
alter table public.members add column if not exists next_of_kin_phone text;
alter table public.members add column if not exists fee_category      text;
alter table public.members add column if not exists course_source     text;
alter table public.members add column if not exists course_note       text;
alter table public.members add column if not exists course_date       date;

alter table public.members drop constraint if exists members_fee_category_ck;
alter table public.members add  constraint members_fee_category_ck
  check (fee_category is null or fee_category in ('Senior','Junior','Concessionary'));
alter table public.members drop constraint if exists members_course_source_ck;
alter table public.members add  constraint members_course_source_ck
  check (course_source is null or course_source in ('club','elsewhere'));
alter table public.members drop constraint if exists members_nok_len_ck;
alter table public.members add  constraint members_nok_len_ck
  check (char_length(coalesce(next_of_kin_name,'')) <= 100 and char_length(coalesce(next_of_kin_phone,'')) <= 30
         and char_length(coalesce(course_note,'')) <= 300);

-- allow 'parent' as a member type (replace whatever check exists on membertype)
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.members'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%membertype%' loop
    execute format('alter table public.members drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.members add constraint members_membertype_ck
  check (membertype in ('beginner','member','parent'));

-- under-18s may have no email of their own (parents hold the login); everyone else needs one
alter table public.members alter column email drop not null;

-- ---------------------------------------------------------------------
-- 2. Parent / guardian links
-- ---------------------------------------------------------------------
create table if not exists public.member_guardians (
  id                 bigint generated always as identity primary key,
  child_id           uuid not null references public.members(id) on delete cascade,
  guardian_member_id uuid not null references public.members(id) on delete cascade,
  relationship       text check (char_length(relationship) <= 40),
  created_at         timestamptz not null default now(),
  unique (child_id, guardian_member_id),
  check (child_id <> guardian_member_id)
);
alter table public.member_guardians enable row level security;

-- true when the signed-in person is a guardian of this child AND the child is still under 18
create or replace function public.is_guardian_of(child uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.member_guardians g
      join public.members c on c.id = g.child_id
     where g.child_id = child
       and g.guardian_member_id = public.my_member_id()
       and (c.dob is null or c.dob > (current_date - interval '18 years')));
$$;
revoke execute on function public.is_guardian_of(uuid) from public, anon;
grant  execute on function public.is_guardian_of(uuid) to authenticated;

drop policy if exists "guardian links read"   on public.member_guardians;
drop policy if exists "guardian links insert" on public.member_guardians;
drop policy if exists "guardian links update" on public.member_guardians;
drop policy if exists "guardian links delete" on public.member_guardians;
drop policy if exists "aal2 guardian insert"  on public.member_guardians;
drop policy if exists "aal2 guardian update"  on public.member_guardians;
drop policy if exists "aal2 guardian delete"  on public.member_guardians;
create policy "guardian links read"   on public.member_guardians for select to authenticated
  using (public.is_committee() or guardian_member_id = public.my_member_id() or child_id = public.my_member_id());
create policy "guardian links insert" on public.member_guardians for insert to authenticated with check (public.is_committee());
create policy "guardian links update" on public.member_guardians for update to authenticated using (public.is_committee()) with check (public.is_committee());
create policy "guardian links delete" on public.member_guardians for delete to authenticated using (public.is_committee());
create policy "aal2 guardian insert"  on public.member_guardians as restrictive for insert to authenticated with check (public.is_aal2());
create policy "aal2 guardian update"  on public.member_guardians as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy "aal2 guardian delete"  on public.member_guardians as restrictive for delete to authenticated using (public.is_aal2());
revoke all on public.member_guardians from anon, authenticated;
grant select, insert, update, delete on public.member_guardians to authenticated;

-- a guardian can read and update (contact fields only, see trigger) their under-18 child's record
drop policy if exists "guardian read child"   on public.members;
drop policy if exists "guardian update child" on public.members;
create policy "guardian read child"   on public.members for select to authenticated using (public.is_guardian_of(id));
create policy "guardian update child" on public.members for update to authenticated
  using (public.is_guardian_of(id)) with check (public.is_guardian_of(id));
-- a child can see who their guardians are (name/contact), so they know who can act for them
drop policy if exists "child read guardian" on public.members;
create policy "child read guardian" on public.members for select to authenticated
  using (exists (select 1 from public.member_guardians g where g.guardian_member_id = members.id and g.child_id = public.my_member_id()));

-- ---------------------------------------------------------------------
-- 3. Non-committee people (members, and guardians editing a child) may change only these columns
-- ---------------------------------------------------------------------
create or replace function public.members_guard_update()
returns trigger language plpgsql set search_path = public as $$
declare
  own_cols text[] := array['name','address1','town','county','postcode','mobile','flagfor_allowphotos',
                           'next_of_kin_name','next_of_kin_phone'];
begin
  if auth.uid() is null or public.is_committee() then
    return new;
  end if;
  if (to_jsonb(new) - own_cols) is distinct from (to_jsonb(old) - own_cols) then
    raise exception 'You can only change contact details, next of kin and photo consent. Ask the committee for anything else.'
      using errcode = '42501';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 4. Club rules, enforced for everything done through the website
--    (the SQL editor, with no signed-in user, is exempt so you can always fix data)
-- ---------------------------------------------------------------------
create or replace function public.members_rules()
returns trigger language plpgsql set search_path = public as $$
declare under18 boolean;
begin
  if auth.uid() is null then return new; end if;
  under18 := new.dob is not null and new.dob > (current_date - interval '18 years');

  if coalesce(trim(new.email),'') = '' and not under18 then
    raise exception 'An email address is needed (only under-18s can be without one).';
  end if;

  if new.membertype in ('beginner','member') then
    if tg_op = 'INSERT' and (coalesce(trim(new.next_of_kin_name),'') = '' or coalesce(trim(new.next_of_kin_phone),'') = '') then
      raise exception 'Next of kin name and phone number are required.';
    end if;
    if tg_op = 'UPDATE'
       and (new.next_of_kin_name is distinct from old.next_of_kin_name or new.next_of_kin_phone is distinct from old.next_of_kin_phone)
       and (coalesce(trim(new.next_of_kin_name),'') = '' or coalesce(trim(new.next_of_kin_phone),'') = '') then
      raise exception 'Next of kin name and phone number cannot be blank.';
    end if;
  end if;

  -- only people with proof of a beginners course (ours or elsewhere) can become members.
  -- people who were already members before this rule existed are not affected.
  if new.membertype = 'member' and (tg_op = 'INSERT' or old.membertype is distinct from 'member') then
    if not coalesce(new.beginnercoursecomplete,false) or new.course_source is null then
      raise exception 'A member needs proof of a completed beginners course: done with the club or elsewhere.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists members_rules on public.members;
create trigger members_rules before insert or update on public.members
  for each row execute function public.members_rules();

-- ---------------------------------------------------------------------
-- 5. Enquiries remember which member they became
-- ---------------------------------------------------------------------
alter table public.enquiries add column if not exists converted_member_id uuid references public.members(id) on delete set null;

-- ---------------------------------------------------------------------
-- 6. Committee tools (checked inside: committee + 2FA, otherwise refused)
-- ---------------------------------------------------------------------
create or replace function public.committee_add_member(p_member jsonb, p_guardians jsonb default '[]'::jsonb, p_enquiry_id bigint default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_type text; v_dob date; v_under18 boolean; v_email text; v_src text;
  g jsonb; v_gid uuid; v_gemail text; n_guard int := 0;
begin
  if not public.is_committee() or not public.is_aal2() then
    raise exception 'Committee with 2FA only.' using errcode = '42501';
  end if;
  v_type  := coalesce(nullif(p_member->>'membertype',''), 'beginner');
  if v_type not in ('beginner','member') then raise exception 'Type must be beginner or member.'; end if;
  if coalesce(trim(p_member->>'name'),'') = '' then raise exception 'Name is required.'; end if;
  v_dob   := nullif(p_member->>'dob','')::date;
  if v_dob is null then raise exception 'Date of birth is required (it decides junior or senior).'; end if;
  v_under18 := v_dob > (current_date - interval '18 years');
  v_email := nullif(lower(trim(p_member->>'email')),'');
  v_src   := nullif(p_member->>'course_source','');
  if v_type = 'member' and v_src is null then
    raise exception 'To make someone a member, record their beginners course: done with the club or elsewhere.';
  end if;
  if v_email is not null and exists (select 1 from public.members where lower(email) = v_email) then
    raise exception 'Someone with that email is already in the members list.';
  end if;
  if v_under18 and jsonb_array_length(coalesce(p_guardians,'[]'::jsonb)) = 0 then
    raise exception 'Under-18s need at least one parent or guardian.';
  end if;

  insert into public.members (title, name, email, mobile, address1, town, county, postcode, dob, membertype,
        next_of_kin_name, next_of_kin_phone, fee_category, archerygbnum, flagfor_allowphotos,
        beginnercoursecomplete, course_source, course_note, course_date, datejoinedclub)
  values (nullif(p_member->>'title',''), trim(p_member->>'name'), v_email, nullif(trim(p_member->>'mobile'),''),
        nullif(trim(p_member->>'address1'),''), nullif(trim(p_member->>'town'),''), nullif(trim(p_member->>'county'),''),
        nullif(trim(p_member->>'postcode'),''), v_dob, v_type,
        nullif(trim(p_member->>'next_of_kin_name'),''), nullif(trim(p_member->>'next_of_kin_phone'),''),
        coalesce(nullif(p_member->>'fee_category',''), case when v_under18 then 'Junior' else 'Senior' end),
        nullif(trim(p_member->>'archerygbnum'),''), coalesce((p_member->>'allow_photos')::boolean,false),
        v_type = 'member' or coalesce((p_member->>'course_done')::boolean,false), v_src,
        nullif(trim(p_member->>'course_note'),''), case when v_src is not null then coalesce(nullif(p_member->>'course_date','')::date, current_date) end,
        case when v_type = 'member' then current_date end)
  returning id into v_id;

  for g in select * from jsonb_array_elements(coalesce(p_guardians,'[]'::jsonb)) loop
    v_gid := nullif(g->>'member_id','')::uuid;
    if v_gid is null then
      v_gemail := nullif(lower(trim(g->>'email')),'');
      if coalesce(trim(g->>'name'),'') = '' or v_gemail is null then
        raise exception 'Each parent or guardian needs a name and an email (they sign in with it).';
      end if;
      if v_gemail = v_email then raise exception 'A parent cannot share the child''s email address.'; end if;
      select id into v_gid from public.members where lower(email) = v_gemail;
      if v_gid is null then
        insert into public.members (name, email, mobile, membertype)
        values (trim(g->>'name'), v_gemail, nullif(trim(g->>'mobile'),''), 'parent') returning id into v_gid;
      end if;
    end if;
    if v_gid = v_id then raise exception 'A person cannot be their own guardian.'; end if;
    insert into public.member_guardians (child_id, guardian_member_id, relationship)
    values (v_id, v_gid, nullif(trim(g->>'relationship'),'')) on conflict do nothing;
    n_guard := n_guard + 1;
  end loop;

  if p_enquiry_id is not null then
    update public.enquiries set status = 'converted', converted_member_id = v_id where id = p_enquiry_id;
  end if;
  return v_id;
end $$;
revoke execute on function public.committee_add_member(jsonb, jsonb, bigint) from public, anon;
grant  execute on function public.committee_add_member(jsonb, jsonb, bigint) to authenticated;

-- record course proof and make a beginner a member
create or replace function public.committee_make_member(p_member uuid, p_source text, p_note text default null, p_date date default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_committee() or not public.is_aal2() then
    raise exception 'Committee with 2FA only.' using errcode = '42501';
  end if;
  if p_source not in ('club','elsewhere') then raise exception 'Course must be done with the club or elsewhere.'; end if;
  update public.members
     set membertype = 'member', beginnercoursecomplete = true, course_source = p_source,
         course_note = nullif(trim(p_note),''), course_date = coalesce(p_date, current_date),
         datejoinedclub = coalesce(datejoinedclub, current_date)
   where id = p_member and membertype = 'beginner';
  if not found then raise exception 'That person is not a beginner on the list.'; end if;
end $$;
revoke execute on function public.committee_make_member(uuid, text, text, date) from public, anon;
grant  execute on function public.committee_make_member(uuid, text, text, date) to authenticated;

commit;

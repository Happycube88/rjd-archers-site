-- RJD Archers: guest archers.
--   * REGISTERED GUESTS: archers from other clubs who register with us and pay to attend club nights.
--     They are people in the members list with type "guest": own login, next of kin, can book club nights
--     later. No beginners-course proof needed (their own club vouches). Committee adds them as usual.
--   * ONE-OFF SHOOT GUESTS: a simple list (name, club, bow, date, event) for visitors at a single shoot.
-- Run once in the Supabase SQL editor AFTER members_family.sql. Safe to run again.
begin;

alter table public.members add column if not exists home_club text check (char_length(home_club) <= 100);
alter table public.members drop constraint if exists members_membertype_ck;
alter table public.members add constraint members_membertype_ck
  check (membertype in ('beginner','member','parent','guest'));

create or replace function public.members_rules()
returns trigger language plpgsql set search_path = public as $$
declare under18 boolean;
begin
  if auth.uid() is null then return new; end if;
  under18 := new.dob is not null and new.dob > (current_date - interval '18 years');

  if coalesce(trim(new.email),'') = '' and not under18 then
    raise exception 'An email address is needed (only under-18s can be without one).';
  end if;

  if new.membertype in ('beginner','member','guest') then
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
  if v_type not in ('beginner','member','guest') then raise exception 'Type must be beginner, member or guest.'; end if;
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
        beginnercoursecomplete, course_source, course_note, course_date, datejoinedclub, home_club)
  values (nullif(p_member->>'title',''), trim(p_member->>'name'), v_email, nullif(trim(p_member->>'mobile'),''),
        nullif(trim(p_member->>'address1'),''), nullif(trim(p_member->>'town'),''), nullif(trim(p_member->>'county'),''),
        nullif(trim(p_member->>'postcode'),''), v_dob, v_type,
        nullif(trim(p_member->>'next_of_kin_name'),''), nullif(trim(p_member->>'next_of_kin_phone'),''),
        coalesce(nullif(p_member->>'fee_category',''), case when v_under18 then 'Junior' else 'Senior' end),
        nullif(trim(p_member->>'archerygbnum'),''), coalesce((p_member->>'allow_photos')::boolean,false),
        v_type = 'member' or coalesce((p_member->>'course_done')::boolean,false), v_src,
        nullif(trim(p_member->>'course_note'),''), case when v_src is not null then coalesce(nullif(p_member->>'course_date','')::date, current_date) end,
        case when v_type = 'member' then current_date end,
        case when v_type = 'guest' then nullif(trim(p_member->>'home_club'),'') end)
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

-- one-off guests at a shoot (not people with logins)
create table if not exists public.shoot_guests (
  id           bigint generated always as identity primary key,
  name         text not null check (char_length(name) between 1 and 100),
  club         text check (char_length(club) <= 100),
  bow_style    text check (char_length(bow_style) <= 40),
  archerygbnum text check (char_length(archerygbnum) <= 30),
  shoot_date   date not null default current_date,
  event        text check (char_length(event) <= 120),
  notes        text check (char_length(notes) <= 300),
  created_at   timestamptz not null default now(),
  created_by   uuid references public.members(id) on delete set null
);
create index if not exists shoot_guests_date_idx on public.shoot_guests (shoot_date desc);
alter table public.shoot_guests enable row level security;
drop policy if exists "shoot guests read"   on public.shoot_guests;
drop policy if exists "shoot guests insert" on public.shoot_guests;
drop policy if exists "shoot guests update" on public.shoot_guests;
drop policy if exists "shoot guests delete" on public.shoot_guests;
drop policy if exists "aal2 shoot guests insert" on public.shoot_guests;
drop policy if exists "aal2 shoot guests update" on public.shoot_guests;
drop policy if exists "aal2 shoot guests delete" on public.shoot_guests;
create policy "shoot guests read"   on public.shoot_guests for select to authenticated using (public.is_committee() or public.is_recordkeeper());
create policy "shoot guests insert" on public.shoot_guests for insert to authenticated with check (public.is_committee());
create policy "shoot guests update" on public.shoot_guests for update to authenticated using (public.is_committee()) with check (public.is_committee());
create policy "shoot guests delete" on public.shoot_guests for delete to authenticated using (public.is_committee());
create policy "aal2 shoot guests insert" on public.shoot_guests as restrictive for insert to authenticated with check (public.is_aal2());
create policy "aal2 shoot guests update" on public.shoot_guests as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy "aal2 shoot guests delete" on public.shoot_guests as restrictive for delete to authenticated using (public.is_aal2());
revoke all on public.shoot_guests from anon, authenticated;
grant select, insert, update, delete on public.shoot_guests to authenticated;

commit;

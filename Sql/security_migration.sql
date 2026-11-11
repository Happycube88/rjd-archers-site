-- =====================================================================
-- RJD Archers - security migration (action-plan steps 2 to 7)
-- Run in the Supabase SQL editor as ONE run. It is a single transaction:
-- if anything fails, nothing is changed.
--
-- NO COMMITTEE YET (empty or test data only): just run it, then run bootstrap_first_committee.sql.
-- COMMITTEE ALREADY FLAGGED: they must have signed in once (a row in auth.users). The script links
-- members to logins by matching email and aborts if none of the committee can be linked.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- STEP 4: link members to logins with auth_id
-- ---------------------------------------------------------------------
create unique index if not exists members_auth_id_uidx
  on public.members (auth_id) where auth_id is not null;

-- rows already created with id = login id
update public.members m set auth_id = m.id
 where m.auth_id is null
   and exists (select 1 from auth.users u where u.id = m.id);

-- everyone else: match on confirmed email
update public.members m set auth_id = u.id
  from auth.users u
 where m.auth_id is null
   and u.email_confirmed_at is not null
   and lower(u.email) = lower(m.email);

-- safety: if any member is already flagged as committee, at least one of them must be linked to a login,
-- otherwise abort (so a real committee cannot be locked out). Test rows with no committee flags are fine:
-- run bootstrap_first_committee.sql afterwards to create the first committee member.
do $$
declare has_flagged boolean; has_linked boolean;
begin
  select
    bool_or(coalesce(membershipcom,false) or coalesce(chaircom,false) or coalesce(secretarycom,false)
         or coalesce(welfarecom,false) or coalesce(tournamentscom,false)),
    bool_or(auth_id is not null and (coalesce(membershipcom,false) or coalesce(chaircom,false) or coalesce(secretarycom,false)
         or coalesce(welfarecom,false) or coalesce(tournamentscom,false)))
  into has_flagged, has_linked
  from public.members;
  if coalesce(has_flagged,false) and not coalesce(has_linked,false) then
    raise exception 'ABORTED: committee members are flagged but none is linked to a login yet. Have them sign in once, then re-run.';
  end if;
  if not coalesce(has_flagged,false) then
    raise notice 'No committee members yet: run bootstrap_first_committee.sql after this.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- STEP 6 (part): record keeper flag
-- ---------------------------------------------------------------------
alter table public.members add column if not exists recordkeeper boolean not null default false;

-- ---------------------------------------------------------------------
-- Helper functions (all use auth_id, not id)
-- ---------------------------------------------------------------------
create or replace function public.is_aal2()
returns boolean language sql stable as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;

create or replace function public.is_committee()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.members
     where auth_id = auth.uid()
       and (coalesce(membershipcom,false) or coalesce(chaircom,false) or coalesce(secretarycom,false)
         or coalesce(welfarecom,false)   or coalesce(tournamentscom,false)));
$$;

create or replace function public.is_recordkeeper()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where auth_id = auth.uid() and recordkeeper);
$$;

create or replace function public.my_member_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.members where auth_id = auth.uid();
$$;

revoke execute on function public.is_committee(), public.is_recordkeeper(), public.my_member_id(), public.is_aal2()
  from public, anon;
grant  execute on function public.is_committee(), public.is_recordkeeper(), public.my_member_id(), public.is_aal2()
  to authenticated;

-- ---------------------------------------------------------------------
-- STEPS 2, 3, 7: members table
-- ---------------------------------------------------------------------
drop policy if exists "Allow public to register as beginners" on public.members;   -- STEP 2
drop policy if exists "Committee full access"                  on public.members;
drop policy if exists "Users can update own profile"           on public.members;
drop policy if exists "Users can view own profile"             on public.members;

revoke all on public.members from anon;                                            -- no public access at all

create policy "members read own"      on public.members for select to authenticated using (auth_id = auth.uid());
create policy "committee read all"     on public.members for select to authenticated using (public.is_committee());
create policy "committee insert"       on public.members for insert to authenticated with check (public.is_committee());
create policy "committee update"       on public.members for update to authenticated using (public.is_committee()) with check (public.is_committee());
create policy "committee delete"       on public.members for delete to authenticated using (public.is_committee());
create policy "members update own row" on public.members for update to authenticated
  using (auth_id = auth.uid()) with check (auth_id = auth.uid());

-- STEP 7: every write needs a 2FA (aal2) session. Restrictive = ANDed with the rules above.
create policy "aal2 insert" on public.members as restrictive for insert to authenticated with check (public.is_aal2());
create policy "aal2 update" on public.members as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy "aal2 delete" on public.members as restrictive for delete to authenticated using (public.is_aal2());

-- STEP 3: a member may change ONLY their own contact fields. Committee may change anything.
-- (A trigger is used because column grants would also stop committee, who share the same role.)
create or replace function public.members_guard_update()
returns trigger language plpgsql set search_path = public as $$
declare
  own_cols text[] := array['name','address1','town','county','postcode','mobile','flagfor_allowphotos'];
begin
  -- SQL editor / service key (no logged-in user) and committee are unrestricted
  if auth.uid() is null or public.is_committee() then
    return new;
  end if;
  if (to_jsonb(new) - own_cols) is distinct from (to_jsonb(old) - own_cols) then
    raise exception 'You can only change your own contact details (name, address, mobile, photo consent).'
      using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists members_guard_update on public.members;
create trigger members_guard_update before update on public.members
  for each row execute function public.members_guard_update();

-- ---------------------------------------------------------------------
-- STEP 2 (replacement): beginner enquiries get their own write-only table
-- ---------------------------------------------------------------------
create table if not exists public.enquiries (
  id             bigint generated always as identity primary key,
  name           text not null check (char_length(name)   between 1 and 100),
  email          text not null check (char_length(email)  between 5 and 254 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  mobile         text check (char_length(mobile)   <= 30),
  postcode       text check (char_length(postcode) <= 12),
  dob            date check (dob between date '1900-01-01' and current_date),
  guardian_name  text check (char_length(guardian_name)  <= 100),
  guardian_email text check (char_length(guardian_email) <= 254),
  guardian_phone text check (char_length(guardian_phone) <= 30),
  status         text not null default 'new' check (status in ('new','contacted','booked','converted','closed')),
  notes          text,
  created_at     timestamptz not null default now()
);
alter table public.enquiries enable row level security;

revoke all on public.enquiries from anon, authenticated;
grant insert (name, email, mobile, postcode, dob, guardian_name, guardian_email, guardian_phone)
  on public.enquiries to anon, authenticated;                      -- the public can add, never read
grant select, update, delete on public.enquiries to authenticated; -- narrowed by the policies below

drop policy if exists "public can add enquiry"  on public.enquiries;
drop policy if exists "committee read enquiries" on public.enquiries;
create policy "public can add enquiry"   on public.enquiries for insert to anon, authenticated with check (status = 'new');
create policy "committee read enquiries" on public.enquiries for select to authenticated using (public.is_committee());
create policy "committee edit enquiries" on public.enquiries for update to authenticated using (public.is_committee()) with check (public.is_committee());
create policy "committee del enquiries"  on public.enquiries for delete to authenticated using (public.is_committee());
create policy "aal2 enq update" on public.enquiries as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy "aal2 enq delete" on public.enquiries as restrictive for delete to authenticated using (public.is_aal2());

-- ---------------------------------------------------------------------
-- STEP 5: member_contacts_directory (view that exposes mobile + email)
-- ---------------------------------------------------------------------
do $$
declare k "char";
begin
  select c.relkind into k from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relname = 'member_contacts_directory';
  if k = 'v' then
    execute 'alter view public.member_contacts_directory set (security_invoker = true)';  -- obey the members rules
    execute 'revoke all on public.member_contacts_directory from anon';
    execute 'grant select on public.member_contacts_directory to authenticated';
  elsif k = 'm' then
    execute 'revoke all on public.member_contacts_directory from anon, authenticated'; -- matviews cannot use RLS
    raise notice 'member_contacts_directory is a materialized view: locked down completely. Tell me what it is for and I will rebuild it safely.';
  else
    raise notice 'member_contacts_directory not found - nothing to do.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- STEP 6: records + 252 progress (record keeper writes; everyone reads records)
-- ---------------------------------------------------------------------
create table if not exists public.records (
  id           bigint generated always as identity primary key,
  environment  text not null default 'indoor' check (environment in ('indoor','outdoor')),
  round        text not null,
  bow_style    text not null,
  class        text not null,
  score        integer not null check (score >= 0),
  archer_name  text not null,
  member_id    uuid references public.members(id) on delete set null,
  shot_date    date,
  date_text    text,
  venue        text,
  club         text default 'RJD Archers',
  notes        text,
  created_at   timestamptz default now()
);
create index if not exists records_filter_idx on public.records (environment, bow_style, round, class);
alter table public.records enable row level security;

create table if not exists public.member_252_progress (
  id         bigint generated always as identity primary key,
  member_id  uuid not null references public.members(id) on delete cascade,
  shoot_date date not null,
  round      text,
  bow_style  text,
  score      integer check (score is null or score >= 0),
  stage      text,
  verified   boolean not null default false,
  notes      text,
  created_at timestamptz default now()
);
alter table public.member_252_progress enable row level security;

drop policy if exists "records readable by all"       on public.records;
drop policy if exists "committee insert records"      on public.records;
drop policy if exists "committee update records"      on public.records;
drop policy if exists "committee delete records"      on public.records;
drop policy if exists "own or committee read 252"     on public.member_252_progress;
drop policy if exists "own or committee add 252"      on public.member_252_progress;
drop policy if exists "committee edit 252"            on public.member_252_progress;
drop policy if exists "committee delete 252"          on public.member_252_progress;

-- records: public read, record keeper write
create policy "records public read"  on public.records for select to anon, authenticated using (true);
create policy "rk insert records"    on public.records for insert to authenticated with check (public.is_recordkeeper());
create policy "rk update records"    on public.records for update to authenticated using (public.is_recordkeeper()) with check (public.is_recordkeeper());
create policy "rk delete records"    on public.records for delete to authenticated using (public.is_recordkeeper());

-- 252: members see their own; members may add their own UNVERIFIED entries; record keeper manages all
create policy "252 read"   on public.member_252_progress for select to authenticated
  using (member_id = public.my_member_id() or public.is_recordkeeper() or public.is_committee());
create policy "252 insert" on public.member_252_progress for insert to authenticated
  with check ((member_id = public.my_member_id() and verified = false) or public.is_recordkeeper());
create policy "252 update" on public.member_252_progress for update to authenticated
  using (public.is_recordkeeper()) with check (public.is_recordkeeper());
create policy "252 delete" on public.member_252_progress for delete to authenticated
  using (public.is_recordkeeper());

-- STEP 7: 2FA on every write
create policy "aal2 rec insert" on public.records as restrictive for insert to authenticated with check (public.is_aal2());
create policy "aal2 rec update" on public.records as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy "aal2 rec delete" on public.records as restrictive for delete to authenticated using (public.is_aal2());
create policy "aal2 252 insert" on public.member_252_progress as restrictive for insert to authenticated with check (public.is_aal2());
create policy "aal2 252 update" on public.member_252_progress as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy "aal2 252 delete" on public.member_252_progress as restrictive for delete to authenticated using (public.is_aal2());

revoke all on public.records, public.member_252_progress from anon;
grant select on public.records to anon;

-- Table rights for logged-in users (newer Supabase projects do not grant these automatically).
-- Row-level security above decides which rows each person can actually touch.
grant select, insert, update, delete on public.members             to authenticated;
grant select, insert, update, delete on public.records             to authenticated;
grant select, insert, update, delete on public.member_252_progress to authenticated;

commit;

-- ---------------------------------------------------------------------
-- AFTER running: make the record keeper(s). Use their member email.
--   update public.members set recordkeeper = true where email = 'recordkeeper@example.com';
-- (Run in the SQL editor: it is exempt from the member-edit guard.)
-- ---------------------------------------------------------------------

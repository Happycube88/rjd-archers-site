-- RJD Archers: committee roles, member status, beginner invitations, email-change control,
-- backup and purge with "last run" dates.
-- Run once in the Supabase SQL editor AFTER the older scripts. Safe to run again.
--
-- What this does
--  1. Treasurer role (treasurercom).
--  2. Only the Chair or Secretary can: change anyone's roles, make someone a member, set a member's status,
--     invite or refuse a beginner, and purge old personal data. Other committee members keep everything
--     else they could do before.
--  3. Member status: active / lapsed / left / purged. People who are not active cannot book or enter.
--  4. The beginner decision (pending / invited / declined) and the committee's private note live in a
--     committee-only table, so a refused beginner can never read them. Only an invited beginner can be
--     made a member. New enquiries that match a declined applicant are closed automatically and flagged.
--  5. Email addresses: members can never change their own email (not on their record, not in their login).
--     They send a request; the Chair, Secretary or Membership approves it. Approving removes the old login,
--     so the person signs in with the new address and sets up 2FA again.
--  6. Backup: only the Chair, Secretary and Membership can take one, through backup_export(). The date it
--     last ran is recorded. Purge dates are recorded too.
--  7. Under-18s can still have no email address (a parent or guardian signs in for them).

-- ---------------------------------------------------------------------
-- 1. New columns
-- ---------------------------------------------------------------------
alter table public.members add column if not exists treasurercom boolean not null default false;
alter table public.members add column if not exists status text not null default 'active';
alter table public.members add column if not exists status_date date;
alter table public.members drop constraint if exists members_status_check;
alter table public.members add constraint members_status_check check (status in ('active','lapsed','left','purged'));

-- Committee-only notes: never readable by the person they are about.
create table if not exists public.member_committee_notes (
  member_id        uuid primary key references public.members(id) on delete cascade,
  join_decision    text not null default 'pending' check (join_decision in ('pending','invited','declined')),
  join_decision_on date,
  note             text check (note is null or char_length(note) <= 200),
  updated_at       timestamptz not null default now()
);
alter table public.member_committee_notes enable row level security;
revoke all on public.member_committee_notes from anon, authenticated;
grant select on public.member_committee_notes to authenticated;
drop policy if exists "committee read notes" on public.member_committee_notes;
create policy "committee read notes" on public.member_committee_notes for select to authenticated using (public.is_committee());

-- ---------------------------------------------------------------------
-- 2. Who counts as what
-- ---------------------------------------------------------------------
create or replace function public.is_committee()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.members
     where auth_id = auth.uid()
       and (coalesce(membershipcom,false) or coalesce(chaircom,false) or coalesce(secretarycom,false)
         or coalesce(welfarecom,false)   or coalesce(tournamentscom,false) or coalesce(treasurercom,false)));
$$;

create or replace function public.is_chair_or_secretary()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                  where auth_id = auth.uid() and (coalesce(chaircom,false) or coalesce(secretarycom,false)));
$$;

-- Chair, Secretary or Membership: backups and email-change approvals.
create or replace function public.is_membership_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members
                  where auth_id = auth.uid()
                    and (coalesce(chaircom,false) or coalesce(secretarycom,false) or coalesce(membershipcom,false)));
$$;
revoke execute on function public.is_chair_or_secretary(), public.is_membership_admin() from public, anon;
grant  execute on function public.is_chair_or_secretary(), public.is_membership_admin() to authenticated;

-- ---------------------------------------------------------------------
-- 3. Guards on the members table
-- ---------------------------------------------------------------------
create or replace function public.members_guard_update()
returns trigger language plpgsql set search_path = public as $$
declare
  own_cols text[] := array['name','address1','town','county','postcode','mobile','flagfor_allowphotos',
                           'next_of_kin_name','next_of_kin_phone'];
begin
  if auth.uid() is null then return new; end if;

  -- The email of someone who has a login changes only through committee_set_email().
  if new.email is distinct from old.email and old.auth_id is not null
     and coalesce(current_setting('rjd.email_ok', true), '') <> 'on' then
    raise exception 'A member''s email is changed by the Chair, Secretary or Membership using Change email.'
      using errcode = '42501';
  end if;

  -- A beginner becomes a member only after being invited, whoever makes the change.
  if new.membertype = 'member' and old.membertype = 'beginner'
     and not exists (select 1 from public.member_committee_notes where member_id = new.id and join_decision = 'invited') then
    raise exception 'Invite them to join first.' using errcode = '42501';
  end if;

  if public.is_chair_or_secretary() then return new; end if;

  if public.is_committee() then
    if coalesce(new.chaircom,false)       is distinct from coalesce(old.chaircom,false)
    or coalesce(new.secretarycom,false)   is distinct from coalesce(old.secretarycom,false)
    or coalesce(new.membershipcom,false)  is distinct from coalesce(old.membershipcom,false)
    or coalesce(new.welfarecom,false)     is distinct from coalesce(old.welfarecom,false)
    or coalesce(new.tournamentscom,false) is distinct from coalesce(old.tournamentscom,false)
    or coalesce(new.treasurercom,false)   is distinct from coalesce(old.treasurercom,false)
    or coalesce(new.recordkeeper,false)   is distinct from coalesce(old.recordkeeper,false)
    or coalesce(new.sessionlead,false)    is distinct from coalesce(old.sessionlead,false) then
      raise exception 'Only the Chair or Secretary can change committee roles.' using errcode = '42501';
    end if;
    if new.status is distinct from old.status then
      raise exception 'Only the Chair or Secretary can change membership status.' using errcode = '42501';
    end if;
    if new.membertype = 'member' and old.membertype is distinct from 'member' then
      raise exception 'Only the Chair or Secretary can make someone a member.' using errcode = '42501';
    end if;
    return new;
  end if;

  if (to_jsonb(new) - own_cols) is distinct from (to_jsonb(old) - own_cols) then
    raise exception 'You can only change contact details, next of kin and photo consent. Ask the committee for anything else.'
      using errcode = '42501';
  end if;
  return new;
end $$;

create or replace function public.members_guard_insert()
returns trigger language plpgsql set search_path = public as $$
begin
  if auth.uid() is null or public.is_chair_or_secretary() then return new; end if;
  if new.membertype = 'member'
     or coalesce(new.chaircom,false) or coalesce(new.secretarycom,false) or coalesce(new.membershipcom,false)
     or coalesce(new.welfarecom,false) or coalesce(new.tournamentscom,false) or coalesce(new.treasurercom,false)
     or coalesce(new.recordkeeper,false) or coalesce(new.sessionlead,false)
     or new.status <> 'active' then
    raise exception 'Only the Chair or Secretary can add a member or set roles. Add them as a beginner, guest or parent.'
      using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists members_guard_insert on public.members;
create trigger members_guard_insert before insert on public.members
  for each row execute function public.members_guard_insert();

-- Status changes get a date, and nobody with a committee role can be marked left.
create or replace function public.members_status_rules()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    new.status_date := current_date;
    if new.status in ('left','purged') and (
         coalesce(new.chaircom,false) or coalesce(new.secretarycom,false) or coalesce(new.membershipcom,false)
      or coalesce(new.welfarecom,false) or coalesce(new.tournamentscom,false) or coalesce(new.treasurercom,false)
      or coalesce(new.recordkeeper,false) or coalesce(new.sessionlead,false)) then
      raise exception 'Remove their committee roles first, then mark them as left.' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists members_status_rules on public.members;
create trigger members_status_rules before insert or update on public.members
  for each row execute function public.members_status_rules();

-- Same rules as before. Under-18s may have no email. A purged record has no email or date of birth by design.
create or replace function public.members_rules()
returns trigger language plpgsql set search_path = public as $$
declare under18 boolean;
begin
  if auth.uid() is null then return new; end if;
  if new.status = 'purged' then return new; end if;
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

  if new.membertype = 'member' and (tg_op = 'INSERT' or old.membertype is distinct from 'member') then
    if not coalesce(new.beginnercoursecomplete,false) or new.course_source is null then
      raise exception 'A member needs proof of a completed beginners course: done with the club or elsewhere.';
    end if;
  end if;
  return new;
end $$;

-- There must always be a Chair or Secretary (only they can grant roles).
create or replace function public.check_one_committee_left()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;
  if not exists (select 1 from public.members where chaircom or secretarycom) then
    raise exception 'There must always be a Chair or Secretary. Give the role to someone else first.' using errcode = '23514';
  end if;
  return null;
end $$;
revoke execute on function public.check_one_committee_left() from public, anon, authenticated;
drop trigger if exists keep_one_committee on public.members;
create constraint trigger keep_one_committee
  after update or delete on public.members
  deferrable initially deferred for each row
  when (old.chaircom or old.secretarycom)
  execute function public.check_one_committee_left();

-- ---------------------------------------------------------------------
-- 4. Beginner decision, member status, joining
-- ---------------------------------------------------------------------
create or replace function public.committee_decide_join(p_member uuid, p_decision text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_chair_or_secretary() or not public.is_aal2() then
    raise exception 'Chair or Secretary with 2FA only.' using errcode = '42501';
  end if;
  if p_decision not in ('pending','invited','declined') then raise exception 'Decision must be invited, declined or pending.'; end if;
  if not exists (select 1 from public.members where id = p_member and membertype = 'beginner') then
    raise exception 'That person is not a beginner on the list.';
  end if;
  insert into public.member_committee_notes (member_id, join_decision, join_decision_on, note)
  values (p_member, p_decision, current_date, nullif(trim(p_note),''))
  on conflict (member_id) do update
     set join_decision = excluded.join_decision, join_decision_on = excluded.join_decision_on,
         note = coalesce(excluded.note, public.member_committee_notes.note), updated_at = now();
end $$;
revoke execute on function public.committee_decide_join(uuid, text, text) from public, anon;
grant  execute on function public.committee_decide_join(uuid, text, text) to authenticated;

create or replace function public.committee_set_status(p_member uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_chair_or_secretary() or not public.is_aal2() then
    raise exception 'Chair or Secretary with 2FA only.' using errcode = '42501';
  end if;
  if p_status not in ('active','lapsed','left') then raise exception 'Status must be active, lapsed or left.'; end if;
  if p_member = public.my_member_id() then raise exception 'You cannot change your own status.'; end if;
  if not exists (select 1 from public.members where id = p_member and status <> 'purged') then
    raise exception 'That person was not found, or has been purged.';
  end if;
  update public.members set status = p_status where id = p_member;
  insert into public.member_committee_notes (member_id, note) values (p_member, nullif(trim(p_note),''))
  on conflict (member_id) do update set note = coalesce(nullif(trim(p_note),''), public.member_committee_notes.note), updated_at = now();
end $$;
revoke execute on function public.committee_set_status(uuid, text, text) from public, anon;
grant  execute on function public.committee_set_status(uuid, text, text) to authenticated;

-- Making a beginner a member: Chair or Secretary, and only after they have been invited.
create or replace function public.committee_make_member(p_member uuid, p_source text, p_note text default null, p_date date default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_chair_or_secretary() or not public.is_aal2() then
    raise exception 'Chair or Secretary with 2FA only.' using errcode = '42501';
  end if;
  if p_source not in ('club','elsewhere') then raise exception 'Course must be done with the club or elsewhere.'; end if;
  if not exists (select 1 from public.members where id = p_member and membertype = 'beginner') then
    raise exception 'That person is not a beginner on the list.';
  end if;
  if not exists (select 1 from public.member_committee_notes where member_id = p_member and join_decision = 'invited') then
    raise exception 'Invite them to join first.';
  end if;
  update public.members
     set membertype = 'member', beginnercoursecomplete = true, course_source = p_source,
         course_note = nullif(trim(p_note),''), course_date = coalesce(p_date, current_date),
         datejoinedclub = coalesce(datejoinedclub, current_date)
   where id = p_member and membertype = 'beginner';
end $$;
revoke execute on function public.committee_make_member(uuid, text, text, date) from public, anon;
grant  execute on function public.committee_make_member(uuid, text, text, date) to authenticated;

-- A new enquiry that matches a declined applicant (same email, or same name and date of birth) is closed and
-- flagged for the Chair or Secretary. The person filling in the form still sees "thank you".
create or replace function public.enquiries_flag_declined()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (
    select 1 from public.members m join public.member_committee_notes n on n.member_id = m.id
     where n.join_decision = 'declined' and m.status <> 'purged'
       and ((m.email is not null and lower(m.email) = lower(new.email))
         or (new.dob is not null and m.dob = new.dob and lower(trim(m.name)) = lower(trim(new.name))))
  ) then
    update public.enquiries set status = 'closed', notes = 'Matches a declined applicant. Chair or Secretary to review.'
     where id = new.id;
  end if;
  return null;
end $$;
revoke execute on function public.enquiries_flag_declined() from public, anon, authenticated;
drop trigger if exists enquiries_flag_declined on public.enquiries;
create trigger enquiries_flag_declined after insert on public.enquiries
  for each row execute function public.enquiries_flag_declined();

-- ---------------------------------------------------------------------
-- 5. Only active people can book or enter
-- ---------------------------------------------------------------------
create or replace function public.book_club_night(p_night uuid, p_member uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare n public.club_nights; m public.members; v_taken int; v_id uuid;
begin
  if auth.uid() is null or not public.is_aal2() then raise exception 'Sign in with your 2FA code first.' using errcode = '42501'; end if;
  select * into n from club_nights where id = p_night for update;
  if not found then raise exception 'Club night not found.' using errcode = '22023'; end if;
  if n.cancelled then raise exception 'This night is cancelled%.', coalesce(' (' || n.cancel_reason || ')', '') using errcode = '22023'; end if;
  select * into m from members where id = p_member;
  if not found or m.membertype not in ('member','guest') or m.status <> 'active' then
    raise exception 'Only current members and registered guests can book.' using errcode = '42501';
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

create or replace function public.enter_tournament(p_tournament uuid, p_member uuid, p_entry jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare m public.members;
begin
  if auth.uid() is null or not public.is_aal2() then
    raise exception 'Sign in with your 2FA code first.' using errcode = '42501';
  end if;
  select * into m from members where id = p_member;
  if not found or m.membertype not in ('member','guest') or m.status <> 'active' then
    raise exception 'Only current members and registered guests can enter.' using errcode = '42501';
  end if;
  if p_member is distinct from public.my_member_id() and not public.is_guardian_of(p_member) then
    raise exception 'You can only enter yourself or your own child.' using errcode = '42501';
  end if;
  return public._insert_entry(p_tournament, p_member, p_entry, false);
end $$;

-- ---------------------------------------------------------------------
-- 6. "Last run" dates for backup and purge
-- ---------------------------------------------------------------------
create table if not exists public.maintenance_log (
  job         text primary key check (job in ('backup','purge')),
  last_run_at timestamptz not null,
  last_run_by uuid references public.members(id) on delete set null,
  detail      text check (detail is null or char_length(detail) <= 200)
);
alter table public.maintenance_log enable row level security;
revoke all on public.maintenance_log from anon, authenticated;

create or replace function public._log_job(p_job text, p_detail text)
returns void language sql security definer set search_path = public as $$
  insert into public.maintenance_log (job, last_run_at, last_run_by, detail)
  values (p_job, now(), public.my_member_id(), left(p_detail, 200))
  on conflict (job) do update
     set last_run_at = excluded.last_run_at, last_run_by = excluded.last_run_by, detail = excluded.detail;
$$;
revoke execute on function public._log_job(text, text) from public, anon, authenticated;

-- Any committee member can see when each job last ran.
create or replace function public.job_last_run()
returns table (job text, last_run_at timestamptz, run_by text, detail text)
language sql stable security definer set search_path = public as $$
  select l.job, l.last_run_at, m.name, l.detail
    from public.maintenance_log l left join public.members m on m.id = l.last_run_by
   where public.is_committee();
$$;
revoke execute on function public.job_last_run() from public, anon;
grant  execute on function public.job_last_run() to authenticated;

-- "I looked and nobody needs purging" still counts as the purge review being done.
create or replace function public.committee_log_purge_review()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_chair_or_secretary() or not public.is_aal2() then
    raise exception 'Chair or Secretary with 2FA only.' using errcode = '42501';
  end if;
  perform public._log_job('purge', 'Review done, nobody purged');
end $$;
revoke execute on function public.committee_log_purge_review() from public, anon;
grant  execute on function public.committee_log_purge_review() to authenticated;

-- ---------------------------------------------------------------------
-- 7. Email changes need the committee
-- ---------------------------------------------------------------------
create table if not exists public.email_change_requests (
  id           bigint generated always as identity primary key,
  member_id    uuid not null references public.members(id) on delete cascade,
  new_email    text not null check (char_length(new_email) between 5 and 254 and new_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  status       text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_at timestamptz not null default now(),
  decided_by   uuid references public.members(id) on delete set null,
  decided_at   timestamptz
);
create unique index if not exists email_change_one_pending on public.email_change_requests (member_id) where status = 'pending';
alter table public.email_change_requests enable row level security;
revoke all on public.email_change_requests from anon, authenticated;
grant select on public.email_change_requests to authenticated;
drop policy if exists "own or admin read email requests" on public.email_change_requests;
create policy "own or admin read email requests" on public.email_change_requests for select to authenticated
  using (member_id = public.my_member_id() or public.is_membership_admin());

create or replace function public.request_email_change(p_new_email text)
returns bigint language plpgsql security definer set search_path = public as $$
declare m public.members; v_email text; v_id bigint;
begin
  if auth.uid() is null or not public.is_aal2() then raise exception 'Sign in with your 2FA code first.' using errcode = '42501'; end if;
  select * into m from public.members where auth_id = auth.uid();
  if not found or m.status <> 'active' then raise exception 'Your login is not linked to a current record.' using errcode = '42501'; end if;
  v_email := lower(trim(coalesce(p_new_email,'')));
  if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That does not look like an email address.'; end if;
  if v_email = lower(coalesce(m.email,'')) then raise exception 'That is already your email address.'; end if;
  delete from public.email_change_requests where member_id = m.id and status = 'pending';
  insert into public.email_change_requests (member_id, new_email) values (m.id, v_email) returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.request_email_change(text) from public, anon;
grant  execute on function public.request_email_change(text) to authenticated;

-- Change someone's email. Removing the old login means the person proves they own the NEW address by
-- signing in with it, and sets up 2FA again. A pending request for the same address is marked approved.
create or replace function public.committee_set_email(p_member uuid, p_new_email text)
returns void language plpgsql security definer set search_path = public as $$
declare m public.members; v_email text; v_auth uuid;
begin
  if not public.is_membership_admin() or not public.is_aal2() then
    raise exception 'Chair, Secretary or Membership with 2FA only.' using errcode = '42501';
  end if;
  select * into m from public.members where id = p_member;
  if not found or m.status = 'purged' then raise exception 'That person was not found.'; end if;
  if m.id = public.my_member_id() then
    raise exception 'You cannot change your own email. Ask another Chair, Secretary or Membership member.';
  end if;
  v_email := nullif(lower(trim(coalesce(p_new_email,''))),'');
  if v_email is null then
    if m.dob is null or m.dob <= current_date - interval '18 years' then
      raise exception 'Only under-18s can be without an email address.';
    end if;
  else
    if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That does not look like an email address.'; end if;
    if exists (select 1 from public.members where lower(email) = v_email and id <> p_member) then
      raise exception 'Someone else already has that email address.';
    end if;
  end if;
  v_auth := m.auth_id;
  perform set_config('rjd.email_ok', 'on', true);
  update public.members set email = v_email, auth_id = null where id = p_member;
  perform set_config('rjd.email_ok', 'off', true);
  if v_auth is not null then delete from auth.users where id = v_auth; end if;
  update public.email_change_requests set status = 'approved', decided_by = public.my_member_id(), decided_at = now()
   where member_id = p_member and status = 'pending' and lower(new_email) is not distinct from v_email;
  update public.email_change_requests set status = 'rejected', decided_by = public.my_member_id(), decided_at = now()
   where member_id = p_member and status = 'pending';
end $$;
revoke execute on function public.committee_set_email(uuid, text) from public, anon;
grant  execute on function public.committee_set_email(uuid, text) to authenticated;

create or replace function public.committee_decide_email_change(p_request bigint, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r public.email_change_requests;
begin
  if not public.is_membership_admin() or not public.is_aal2() then
    raise exception 'Chair, Secretary or Membership with 2FA only.' using errcode = '42501';
  end if;
  select * into r from public.email_change_requests where id = p_request and status = 'pending';
  if not found then raise exception 'That request is not waiting for a decision.'; end if;
  if p_approve then
    perform public.committee_set_email(r.member_id, r.new_email);
  else
    update public.email_change_requests set status = 'rejected', decided_by = public.my_member_id(), decided_at = now() where id = p_request;
  end if;
end $$;
revoke execute on function public.committee_decide_email_change(bigint, boolean) from public, anon;
grant  execute on function public.committee_decide_email_change(bigint, boolean) to authenticated;

-- Belt and braces: the login system itself must not let anyone change an email address on their own either.
-- (Supabase lets a signed-in user ask for an email change straight from the browser.) Removing a login and
-- creating a new one is not an update, so the approved route above is unaffected.
create or replace function public.block_auth_email_change()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.email is distinct from old.email
     or (coalesce(new.email_change,'') <> '' and new.email_change is distinct from old.email_change) then
    raise exception 'Email addresses are changed by the committee. Send a request from your profile.';
  end if;
  return new;
end $$;
drop trigger if exists block_auth_email_change on auth.users;
create trigger block_auth_email_change before update of email, email_change on auth.users
  for each row execute function public.block_auth_email_change();

-- ---------------------------------------------------------------------
-- 8. Backup: Chair, Secretary and Membership only, with the date recorded
-- ---------------------------------------------------------------------
create or replace function public.backup_export()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.is_membership_admin() or not public.is_aal2() then
    raise exception 'Chair, Secretary or Membership with 2FA only.' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'members',                (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.members t),
    'member_committee_notes', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.member_committee_notes t),
    'member_guardians',       (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.member_guardians t),
    'enquiries',              (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.enquiries t),
    'contact_messages',       (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.contact_messages t),
    'email_change_requests',  (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.email_change_requests t),
    'records',                (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.records t),
    'rounds',                 (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.rounds t),
    'member_252_progress',    (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.member_252_progress t),
    'badge_252_awards',       (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.badge_252_awards t),
    'badge_252_thresholds',   (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.badge_252_thresholds t),
    'tournaments',            (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.tournaments t),
    'tournament_entries',     (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.tournament_entries t),
    'club_nights',            (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.club_nights t),
    'club_night_bookings',    (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.club_night_bookings t),
    'club_night_rules',       (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.club_night_rules t),
    'club_night_defaults',    (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.club_night_defaults t),
    'shoot_guests',           (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.shoot_guests t)
  ) into r;
  perform public._log_job('backup', 'Backup downloaded');
  return r;
end $$;
revoke execute on function public.backup_export() from public, anon;
grant  execute on function public.backup_export() to authenticated;

-- ---------------------------------------------------------------------
-- 9. Purge: remove a former member's personal data (Chair or Secretary, with 2FA)
--    Allowed for people marked left or lapsed, or beginners the committee declined.
--    Kept on purpose: tournament fees and paid flags, club night booking counts, and (unless you choose to
--    blank them) the names on public club records. Purging also ends the "declined" block.
-- ---------------------------------------------------------------------
create or replace function public.committee_purge_member(p_member uuid, p_confirm text, p_blank_records boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m public.members; v_email text; v_auth uuid;
  n_links int := 0; n_entries int := 0; n_252 int := 0; n_enq int := 0; n_msg int := 0; n_records int := 0;
begin
  if not public.is_chair_or_secretary() or not public.is_aal2() then
    raise exception 'Chair or Secretary with 2FA only.' using errcode = '42501';
  end if;
  select * into m from public.members where id = p_member;
  if not found then raise exception 'That person was not found.'; end if;
  if m.id = public.my_member_id() then raise exception 'You cannot purge your own record.'; end if;
  if m.status = 'purged' then raise exception 'That record has already been purged.'; end if;
  if not (m.status in ('left','lapsed')
          or exists (select 1 from public.member_committee_notes where member_id = p_member and join_decision = 'declined')) then
    raise exception 'Mark them as left or lapsed first (or decline them if they are a beginner).';
  end if;
  if coalesce(m.chaircom,false) or coalesce(m.secretarycom,false) or coalesce(m.membershipcom,false)
     or coalesce(m.welfarecom,false) or coalesce(m.tournamentscom,false) or coalesce(m.treasurercom,false)
     or coalesce(m.recordkeeper,false) or coalesce(m.sessionlead,false) then
    raise exception 'Remove their committee roles first.';
  end if;
  if lower(trim(coalesce(p_confirm,''))) is distinct from lower(trim(m.name)) then
    raise exception 'Type their full name exactly to confirm.';
  end if;
  if exists (
    select 1 from public.member_guardians g
      join public.members c on c.id = g.child_id
     where g.guardian_member_id = p_member and c.status <> 'purged'
       and c.dob is not null and c.dob > current_date - interval '18 years'
       and not exists (select 1 from public.member_guardians g2 where g2.child_id = g.child_id and g2.guardian_member_id <> p_member)
  ) then
    raise exception 'They are the only parent or guardian of an under-18 member. Add another guardian, or purge the child first.';
  end if;

  v_email := lower(m.email); v_auth := m.auth_id;

  delete from public.member_guardians where child_id = p_member or guardian_member_id = p_member;
  get diagnostics n_links = row_count;

  delete from public.member_252_progress where member_id = p_member;
  get diagnostics n_252 = row_count;
  delete from public.badge_252_awards where member_id = p_member;
  delete from public.email_change_requests where member_id = p_member;
  delete from public.member_committee_notes where member_id = p_member;

  update public.tournament_entries
     set title = null, agb_no = null, surname = 'Removed', forename = 'Removed', club = 'Removed',
         special_needs = null, dob = date '1900-01-01', contact_name = null, contact_address = null,
         contact_phone = null, contact_email = null, notes = null
   where member_id = p_member;
  get diagnostics n_entries = row_count;

  select count(*) into n_records from public.records where member_id = p_member;
  if p_blank_records then
    update public.records set archer_name = 'Former member', member_id = null where member_id = p_member;
  end if;

  if v_email is not null then
    delete from public.enquiries where lower(email) = v_email or converted_member_id = p_member;
    get diagnostics n_enq = row_count;
    delete from public.contact_messages where lower(email) = v_email;
    get diagnostics n_msg = row_count;
  else
    delete from public.enquiries where converted_member_id = p_member;
    get diagnostics n_enq = row_count;
  end if;

  perform set_config('rjd.email_ok', 'on', true);
  update public.members
     set title = null, name = 'Former member', address1 = null, town = null, county = null, postcode = null,
         mobile = null, email = null, archerygbnum = null, dob = null, next_of_kin_name = null, next_of_kin_phone = null,
         home_club = null, course_note = null, flagfor_allowphotos = false, auth_id = null,
         status = 'purged'
   where id = p_member;
  perform set_config('rjd.email_ok', 'off', true);

  if v_auth is not null then
    delete from auth.users where id = v_auth;   -- their login, sessions and 2FA go with it
  end if;

  perform public._log_job('purge', 'Purged one record');
  return jsonb_build_object('links_removed', n_links, 'scores_removed', n_252, 'entries_anonymised', n_entries,
                            'records_naming_them', n_records, 'records_blanked', p_blank_records,
                            'enquiries_removed', n_enq, 'messages_removed', n_msg, 'login_removed', v_auth is not null);
end $$;
revoke execute on function public.committee_purge_member(uuid, text, boolean) from public, anon;
grant  execute on function public.committee_purge_member(uuid, text, boolean) to authenticated;

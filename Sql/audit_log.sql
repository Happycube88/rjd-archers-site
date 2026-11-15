-- RJD Archers: committee audit log. Run after roles_status_purge.sql. Safe to run twice.
-- An append-only record of sensitive changes. Rows cannot be edited or deleted by anyone using the website,
-- including committee members and the Chair. Only the Chair, Secretary and Membership can read it.
-- It stores member ids, not names or emails, so a purged person shows as "Former member" and no personal data is kept.

create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor_id    uuid,                  -- member who did it (null = database administrator or system)
  action      text not null,
  subject_id  uuid,                  -- member it was done to
  detail      text check (detail is null or char_length(detail) <= 300)
);
alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon, authenticated;
revoke truncate on public.audit_log from public;

create or replace function public.audit_log_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'The audit log cannot be changed or deleted.' using errcode = '42501';
end $$;
drop trigger if exists audit_log_no_change on public.audit_log;
create trigger audit_log_no_change before update or delete on public.audit_log
  for each row execute function public.audit_log_immutable();
drop trigger if exists audit_log_no_truncate on public.audit_log;
create trigger audit_log_no_truncate before truncate on public.audit_log
  for each statement execute function public.audit_log_immutable();

create or replace function public._audit(p_action text, p_subject uuid, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (actor_id, action, subject_id, detail)
  values (case when auth.uid() is null then null else public.my_member_id() end, p_action, p_subject, left(p_detail, 300));
end $$;
revoke execute on function public._audit(text, uuid, text) from public, anon, authenticated;

-- Members: roles, status, type, email, added, removed.
create or replace function public.audit_members()
returns trigger language plpgsql security definer set search_path = public as $$
declare r text; chg text := ''; roles text[] := array['chaircom','secretarycom','membershipcom','welfarecom','tournamentscom','treasurercom','recordkeeper','sessionlead'];
        o jsonb; n jsonb;
begin
  if tg_op = 'INSERT' then
    perform public._audit('member added', new.id, 'type ' || coalesce(new.membertype,'?'));
    return null;
  elsif tg_op = 'DELETE' then
    perform public._audit('member record deleted', old.id, null);
    return null;
  end if;
  o := to_jsonb(old); n := to_jsonb(new);
  foreach r in array roles loop
    if coalesce((o->>r)::boolean,false) is distinct from coalesce((n->>r)::boolean,false) then
      perform public._audit(case when coalesce((n->>r)::boolean,false) then 'role granted' else 'role removed' end, new.id,
        case r when 'chaircom' then 'Chair' when 'secretarycom' then 'Secretary' when 'membershipcom' then 'Membership'
               when 'welfarecom' then 'Welfare' when 'tournamentscom' then 'Tournaments' when 'treasurercom' then 'Treasurer'
               when 'recordkeeper' then 'Record keeper' else 'Club night setup' end);
    end if;
  end loop;
  if new.status is distinct from old.status then perform public._audit('status changed', new.id, old.status || ' to ' || new.status); end if;
  if new.membertype is distinct from old.membertype then perform public._audit('member type changed', new.id, old.membertype || ' to ' || new.membertype); end if;
  if new.email is distinct from old.email then perform public._audit('email changed', new.id, null); end if;
  if new.fee_category is distinct from old.fee_category then perform public._audit('fee category changed', new.id, coalesce(old.fee_category,'none') || ' to ' || coalesce(new.fee_category,'none')); end if;
  return null;
end $$;
revoke execute on function public.audit_members() from public, anon, authenticated;
drop trigger if exists audit_members on public.members;
create trigger audit_members after insert or update or delete on public.members
  for each row execute function public.audit_members();

-- Beginner decisions.
create or replace function public.audit_decisions()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.join_decision is distinct from old.join_decision then
    if new.join_decision <> 'pending' then perform public._audit('beginner ' || new.join_decision, new.member_id, null); end if;
  end if;
  return null;
end $$;
revoke execute on function public.audit_decisions() from public, anon, authenticated;
drop trigger if exists audit_decisions on public.member_committee_notes;
create trigger audit_decisions after insert or update on public.member_committee_notes
  for each row execute function public.audit_decisions();

-- Email change requests decided.
create or replace function public.audit_email_requests()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then perform public._audit('email change requested', new.member_id, null);
  elsif new.status is distinct from old.status then perform public._audit('email change ' || new.status, new.member_id, null); end if;
  return null;
end $$;
revoke execute on function public.audit_email_requests() from public, anon, authenticated;
drop trigger if exists audit_email_requests on public.email_change_requests;
create trigger audit_email_requests after insert or update on public.email_change_requests
  for each row execute function public.audit_email_requests();

-- Backups and purges.
create or replace function public._log_job(p_job text, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.maintenance_log (job, last_run_at, last_run_by, detail)
  values (p_job, now(), public.my_member_id(), left(p_detail, 200))
  on conflict (job) do update
     set last_run_at = excluded.last_run_at, last_run_by = excluded.last_run_by, detail = excluded.detail;
  perform public._audit(p_job, null, p_detail);
end $$;
revoke execute on function public._log_job(text, text) from public, anon, authenticated;

-- Reading the log: Chair, Secretary and Membership only.
create or replace function public.audit_view(p_limit int default 300)
returns table (at timestamptz, actor text, action text, subject text, detail text)
language sql stable security definer set search_path = public as $$
  select a.at,
         case when a.actor_id is null then 'System / database administrator' else coalesce(ma.name, 'Former member') end,
         a.action,
         case when a.subject_id is null then '' else coalesce(ms.name, 'Former member') end,
         a.detail
    from public.audit_log a
    left join public.members ma on ma.id = a.actor_id
    left join public.members ms on ms.id = a.subject_id
   where public.is_membership_admin()
   order by a.id desc
   limit least(coalesce(p_limit, 300), 1000);
$$;
revoke execute on function public.audit_view(int) from public, anon;
grant  execute on function public.audit_view(int) to authenticated;

-- RJD Archers: audit log, part 2. Run after audit_log.sql. Safe to run twice.
-- Adds club nights, tournaments and entries, club records, 252 verification and badges, one-off guests,
-- website messages and enquiries (committee responses only). Nothing personal is written to the log.
-- Not logged: ordinary club night bookings (too many, and members make them), and forms arriving from
-- the public (so spam can never fill a log that cannot be emptied).

create or replace function public.audit_events()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r jsonb := to_jsonb(coalesce(new, old));
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  subj uuid := nullif(r->>'member_id','')::uuid;
  v_act text; v_det text; v_name text;
begin
  if tg_table_name in ('contact_messages','enquiries') and (auth.uid() is null or tg_op <> 'UPDATE') then return null; end if;

  if tg_table_name = 'club_nights' then
    v_det := (r->>'night_date') || ' ' || coalesce(r->>'kind','');
    if tg_op = 'INSERT' then v_act := 'club night created';
    elsif tg_op = 'DELETE' then v_act := 'club night deleted';
    elsif coalesce((o->>'cancelled')::boolean,false) is distinct from coalesce((n->>'cancelled')::boolean,false) then
      v_act := case when (n->>'cancelled')::boolean then 'club night cancelled' else 'club night restored' end;
    elsif (o - 'created_at' - 'generated_for') is distinct from (n - 'created_at' - 'generated_for') then v_act := 'club night changed';
    else return null; end if;

  elsif tg_table_name = 'tournaments' then
    v_det := left(coalesce(r->>'name',''), 120);
    if tg_op = 'INSERT' then v_act := 'tournament created';
    elsif tg_op = 'DELETE' then v_act := 'tournament deleted';
    elsif o->>'published' is distinct from n->>'published' then v_act := case when (n->>'published')::boolean then 'tournament published' else 'tournament unpublished' end;
    elsif (o - 'created_at') is distinct from (n - 'created_at') then v_act := 'tournament changed';
    else return null; end if;

  elsif tg_table_name = 'tournament_entries' then
    select name into v_name from public.tournaments where id = (r->>'tournament_id')::uuid;
    v_det := left(coalesce(v_name,''), 120);
    if tg_op = 'INSERT' then v_act := 'tournament entry added';
    elsif tg_op = 'DELETE' then v_act := 'tournament entry removed';
    elsif o->>'status' is distinct from n->>'status' then v_act := 'tournament entry status'; v_det := v_det || ': ' || coalesce(o->>'status','') || ' to ' || coalesce(n->>'status','');
    elsif o->>'paid' is distinct from n->>'paid' then v_act := case when (n->>'paid')::boolean then 'tournament entry marked paid' else 'tournament entry marked unpaid' end;
    elsif (o - 'created_at') is distinct from (n - 'created_at') then v_act := 'tournament entry edited';
    else return null; end if;

  elsif tg_table_name = 'records' then
    v_det := left(coalesce(r->>'round','') || ' ' || coalesce(r->>'bow_style','') || ' ' || coalesce(r->>'score',''), 120);
    if tg_op = 'INSERT' then v_act := 'club record added';
    elsif tg_op = 'DELETE' then v_act := 'club record deleted';
    elsif (o - 'created_at') is distinct from (n - 'created_at') then v_act := 'club record changed';
    else return null; end if;

  elsif tg_table_name = 'member_252_progress' then
    if tg_op = 'UPDATE' and o->>'verified' is distinct from n->>'verified' then
      v_act := case when (n->>'verified')::boolean then '252 score verified' else '252 score unverified' end;
      v_det := coalesce(r->>'bow_style','') || ' ' || coalesce(r->>'score','');
    else return null; end if;

  elsif tg_table_name = 'badge_252_awards' then
    if tg_op = 'INSERT' then v_act := '252 badge awarded'; v_det := coalesce(r->>'bow_style','') || ' ' || coalesce(r->>'distance_yds','') || ' yds';
    elsif tg_op = 'DELETE' then v_act := '252 badge removed'; v_det := coalesce(r->>'bow_style','');
    else return null; end if;

  elsif tg_table_name = 'shoot_guests' then
    if tg_op = 'INSERT' then v_act := 'one-off guest added';
    elsif tg_op = 'DELETE' then v_act := 'one-off guest removed';
    else return null; end if;
    v_det := left(coalesce(r->>'event','') || ' ' || coalesce(r->>'shoot_date',''), 120);

  elsif tg_table_name = 'contact_messages' then
    if o->>'status' is distinct from n->>'status' then v_act := 'website message status'; v_det := 'message ' || (r->>'id') || ': ' || coalesce(o->>'status','') || ' to ' || coalesce(n->>'status','');
    elsif o->>'notes' is distinct from n->>'notes' then v_act := 'website message note edited'; v_det := 'message ' || (r->>'id');
    else return null; end if;

  elsif tg_table_name = 'enquiries' then
    if o->>'converted_member_id' is distinct from n->>'converted_member_id' and n->>'converted_member_id' is not null then
      v_act := 'enquiry turned into a person'; v_det := 'enquiry ' || (r->>'id'); subj := (n->>'converted_member_id')::uuid;
    elsif o->>'status' is distinct from n->>'status' then v_act := 'enquiry status'; v_det := 'enquiry ' || (r->>'id') || ': ' || coalesce(o->>'status','') || ' to ' || coalesce(n->>'status','');
    else return null; end if;

  elsif tg_table_name in ('club_night_rules','club_night_defaults') then
    v_act := 'club night pattern changed'; v_det := tg_table_name || ' ' || lower(tg_op);
  else
    return null;
  end if;

  perform public._audit(v_act, subj, v_det);
  return null;
end $$;
revoke execute on function public.audit_events() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['club_nights','tournaments','tournament_entries','records','member_252_progress','badge_252_awards',
                           'shoot_guests','contact_messages','enquiries','club_night_rules','club_night_defaults'] loop
    execute format('drop trigger if exists audit_events on public.%I', t);
    execute format('create trigger audit_events after insert or update or delete on public.%I for each row execute function public.audit_events()', t);
  end loop;
end $$;

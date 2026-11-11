-- Contact us form: public can send a message, only the committee (with 2FA) can read or change them.
create table if not exists public.contact_messages (
  id         bigint generated always as identity primary key,
  name       text not null check (char_length(name) between 1 and 100),
  email      text not null check (char_length(email) between 5 and 254 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  topic      text not null check (topic in ('Beginners Course','Club Membership','Tournaments','General Enquiry')),
  message    text not null check (char_length(message) between 1 and 3000),
  status     text not null default 'new' check (status in ('new','replied','closed')),
  notes      text check (char_length(notes) <= 2000),
  created_at timestamptz not null default now()
);
alter table public.contact_messages enable row level security;
revoke all on public.contact_messages from anon, authenticated;
grant insert (name, email, topic, message) on public.contact_messages to anon, authenticated;
grant select, update, delete on public.contact_messages to authenticated;

drop policy if exists "public can send message"   on public.contact_messages;
drop policy if exists "committee read messages"   on public.contact_messages;
drop policy if exists "committee edit messages"   on public.contact_messages;
drop policy if exists "committee delete messages" on public.contact_messages;
drop policy if exists "aal2 msg update"           on public.contact_messages;
drop policy if exists "aal2 msg delete"           on public.contact_messages;
create policy "public can send message"   on public.contact_messages for insert to anon, authenticated with check (status = 'new');
create policy "committee read messages"   on public.contact_messages for select to authenticated using (public.is_committee());
create policy "committee edit messages"   on public.contact_messages for update to authenticated using (public.is_committee()) with check (public.is_committee());
create policy "committee delete messages" on public.contact_messages for delete to authenticated using (public.is_committee());
create policy "aal2 msg update" on public.contact_messages as restrictive for update to authenticated using (public.is_aal2()) with check (public.is_aal2());
create policy "aal2 msg delete" on public.contact_messages as restrictive for delete to authenticated using (public.is_aal2());

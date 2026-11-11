-- RJD Archers club records - Supabase schema (v2)
-- Works with your EXISTING members table + is_committee() function.
-- Do NOT recreate members. Run this in the SQL editor.

create table public.records (
  id           bigint generated always as identity primary key,
  environment  text not null default 'indoor' check (environment in ('indoor','outdoor')),
  round        text not null,
  bow_style    text not null,
  class        text not null,
  score        integer not null check (score >= 0),
  archer_name  text not null,
  shot_date    date,
  date_text    text,
  venue        text,
  club         text default 'RJD Archers',
  notes        text,
  created_at   timestamptz default now()
);
create index records_filter_idx on public.records (environment, bow_style, round, class);

alter table public.records enable row level security;

-- Anyone can read
create policy "records readable by all" on public.records for select using (true);

-- Only committee members can change records
create policy "committee insert records" on public.records for insert to authenticated with check (public.is_committee());
create policy "committee update records" on public.records for update to authenticated using (public.is_committee()) with check (public.is_committee());
create policy "committee delete records" on public.records for delete to authenticated using (public.is_committee());

-- ---------- 252 progress, linked to your existing members table ----------
create table public.member_252_progress (
  id         bigint generated always as identity primary key,
  member_id  uuid not null references public.members(id) on delete cascade,
  shoot_date date not null,
  round      text,
  bow_style  text,
  score      integer,
  stage      text,
  verified   boolean default false,
  notes      text,
  created_at timestamptz default now()
);
alter table public.member_252_progress enable row level security;

create policy "own or committee read 252" on public.member_252_progress
  for select to authenticated using (member_id = auth.uid() or public.is_committee());
create policy "own or committee add 252" on public.member_252_progress
  for insert to authenticated with check (member_id = auth.uid() or public.is_committee());
create policy "committee edit 252" on public.member_252_progress
  for update to authenticated using (public.is_committee()) with check (public.is_committee());
create policy "committee delete 252" on public.member_252_progress
  for delete to authenticated using (public.is_committee());

-- Sample RJD Archers rows
insert into public.records (environment, round, bow_style, class, score, archer_name, shot_date, date_text, venue) values
('indoor','Worcester','Bare Bow','Lady Master 50+',223,'Amanda Bohen','2026-03-29','29/03/2026','RJD Archers Worcester Tournament'),
('indoor','Worcester','Compound Unlimited','Gent',300,'David Harding','2024-04-07','07/04/2024','Castle Archers'),
('indoor','Worcester','Compound Unlimited','Lady Master 50+',275,'Amanda Bohen','2024-03-24','24/03/2024','RJD Archers'),
('indoor','Vegas (300)','Longbow','Lady',34,'Jane Downer','2024-12-29','29/12/2024','Deer Park Archers Vegas 2024'),
('indoor','WA 18m','Bare Bow','Lady Master 50+',489,'Amanda Bohen','2026-02-01','01/02/2026','RJD Archers Indoor Tournament'),
('indoor','WA 25m','Long Bow','Lady',201,'Jane Downer','2023-03-19','19/03/2023','RJD Archers');

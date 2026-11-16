-- RJD Archers: News posts. Run after audit_log.sql. Safe to run twice.
create table if not exists public.news_posts (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(title) between 3 and 120),
  body        text not null check (char_length(body) between 1 and 5000),
  category    text not null default 'News' check (category in ('News','Event','Result','Notice')),
  pinned      boolean not null default false,
  published   boolean not null default false,
  posted_on   date not null default current_date,
  created_by  uuid default public.my_member_id(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.news_posts enable row level security;
revoke all on public.news_posts from anon, authenticated;
grant select on public.news_posts to anon, authenticated;
grant insert, update, delete on public.news_posts to authenticated;
drop policy if exists "public reads published news" on public.news_posts;
create policy "public reads published news" on public.news_posts for select to anon, authenticated using (published);
drop policy if exists "committee reads all news" on public.news_posts;
create policy "committee reads all news" on public.news_posts for select to authenticated using (public.is_committee());
drop policy if exists "committee adds news" on public.news_posts;
create policy "committee adds news" on public.news_posts for insert to authenticated with check (public.is_committee() and public.is_aal2());
drop policy if exists "committee edits news" on public.news_posts;
create policy "committee edits news" on public.news_posts for update to authenticated using (public.is_committee() and public.is_aal2()) with check (public.is_committee() and public.is_aal2());
drop policy if exists "committee deletes news" on public.news_posts;
create policy "committee deletes news" on public.news_posts for delete to authenticated using (public.is_committee() and public.is_aal2());

create or replace function public.news_touch()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists news_touch on public.news_posts;
create trigger news_touch before update on public.news_posts for each row execute function public.news_touch();

create or replace function public.audit_news()
returns trigger language plpgsql security definer set search_path = public as $$
declare t text := left(coalesce(new.title, old.title), 120);
begin
  if tg_op = 'INSERT' then perform public._audit('news post created', null, t);
  elsif tg_op = 'DELETE' then perform public._audit('news post deleted', null, t);
  elsif old.published is distinct from new.published then perform public._audit(case when new.published then 'news post published' else 'news post unpublished' end, null, t);
  else perform public._audit('news post edited', null, t); end if;
  return null;
end $$;
revoke execute on function public.audit_news() from public, anon, authenticated;
drop trigger if exists audit_news on public.news_posts;
create trigger audit_news after insert or update or delete on public.news_posts for each row execute function public.audit_news();

insert into public.news_posts (title, body, category, pinned, published)
select 'Welcome to our new website', E'Our new website is here. You can now sign in, book club nights, enter tournaments and keep your own details up to date.\n\nEdit or replace this post from the Committee area, then publish it.', 'News', true, false
where not exists (select 1 from public.news_posts);

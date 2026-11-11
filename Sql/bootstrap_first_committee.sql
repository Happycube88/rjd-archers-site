-- Make YOURSELF the first committee member + record keeper.
-- Before running: you must have signed in on the live site once (so your login exists).
--
-- EDIT THESE TWO VALUES (keep the quotes):
--   your name, and the email you signed in with.
--   Tip: if only ONE person has ever signed in, leave the email as 'AUTO'.
with me as (
  select 'YOUR FULL NAME'::text as full_name,
         'YOUR-EMAIL@example.com'::text as email
)
insert into public.members (name, email, membertype, chaircom, secretarycom, membershipcom, recordkeeper, auth_id)
select me.full_name, u.email, 'member', true, true, true, true, u.id
  from me
  join auth.users u
    on lower(u.email) = lower(me.email)
    or (me.email = 'AUTO' and (select count(*) from auth.users) = 1)
on conflict (email) do update
   set auth_id = excluded.auth_id, chaircom = true, secretarycom = true, membershipcom = true, recordkeeper = true;

-- RESULT: you should see ONE row below with your name, auth_id filled in, and true under chaircom + recordkeeper.
-- If the table is empty, the email did not match a login. Check the spelling against this list:
--   select email, email_confirmed_at from auth.users order by created_at desc;
select name, email, auth_id, chaircom, recordkeeper from public.members where chaircom is true;

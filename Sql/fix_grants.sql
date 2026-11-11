-- Sets EXACT table rights for the public (anon) and logged-in (authenticated) roles.
-- Removes surplus rights (TRUNCATE, TRIGGER, REFERENCES) and re-grants only what the site needs.
-- Safe to run more than once. Row-level security + the 2FA rule then decide who can do what.

revoke all on public.members, public.records, public.member_252_progress from anon, authenticated;

grant select, insert, update, delete on public.members             to authenticated;
grant select, insert, update, delete on public.records             to authenticated;
grant select, insert, update, delete on public.member_252_progress to authenticated;
grant select                         on public.records             to anon;       -- records are public

-- enquiries: anon may only ADD (set by the migration); committee reads/edits via authenticated. Re-assert it:
revoke all on public.enquiries from anon, authenticated;
grant insert (name, email, mobile, postcode, dob, guardian_name, guardian_email, guardian_phone)
  on public.enquiries to anon, authenticated;
grant select, update, delete on public.enquiries to authenticated;

-- contacts view: logged-in only, read only (it follows the members rules)
revoke all on public.member_contacts_directory from anon, authenticated;
grant select on public.member_contacts_directory to authenticated;

-- Check what each role now holds:
select grantee, table_name, string_agg(privilege_type, ', ' order by privilege_type) as rights
  from information_schema.role_table_grants
 where table_schema = 'public' and grantee in ('anon','authenticated')
 group by grantee, table_name order by grantee, table_name;

# RJD Archers website

Website for **RJD Archers**, an archery club in South Wales.
Live site: https://rjd-2qa.pages.dev (the club's own domain, rjdarchers.co.uk, is being moved across).

Public pages show club information, tournaments and records. Members, parents, guests and the committee can sign in to update their own details, book club nights, enter tournaments and (committee only) manage people and events.

## How it is built

| Part | What | Where |
|---|---|---|
| Pages | Plain HTML, Tailwind CSS and a little JavaScript. No build step | this repo |
| Hosting | Cloudflare Pages, project `rjd`, deploys automatically from `main` | Cloudflare |
| Sign-up form | `functions/api/register.js`, a Cloudflare Pages Function | this repo |
| Database and logins | Supabase (Postgres), project `RJD`, region eu-west-2 | Supabase |

## Folder guide

```
index.html, Beginners.html, fees.html ...   public pages
tournaments.html                            2027 tournaments and entry information
records.html                                club records and 252 badge progress
members.html                                members area: sign-in and task cards
committee.html                              committee area: sign-in and task cards
help-2fa.html                               how to set up two-factor sign-in
site-nav.js                                 the shared menu used by every page
auth-status.js                              the My account menu in the header
db/                                         pages that talk to the database
downloads/                                  printable 2027 tournament entry forms
functions/api/register.js                   beginner enquiry form handler
sql/                                        database setup scripts (see below)
_headers                                    browser security headers for Cloudflare
BACKUP_AND_RESTORE.md                       backup routine and restore steps
```

## Security in one paragraph

Everything that matters is enforced in the database with row-level security, not in the web pages. Anyone can read public club records. Personal details are visible only to the person they belong to, a parent of a child under 18, and the committee. **Any change needs two-factor sign-in (an authenticator app).** The site holds only the public Supabase "anon" key, which is designed to be public. **Never put passwords, the Supabase service key, SMTP passwords or backup files in this repo; it is public.**

## Database (`sql/`)

Run the scripts in the Supabase SQL editor, in this order, when building a new project:

1. `schema.sql`
2. `security_migration.sql`
3. `members_family.sql`
4. `committee_edit_and_badges.sql`
5. `badge_252.sql`
6. `rounds_and_linking.sql`
7. `fix_grants.sql`
8. `guests.sql`
9. `tournaments.sql`
10. `club_nights.sql`
11. `club_night_schedule.sql`
12. `bootstrap_first_committee.sql` (edit the email first; creates the first committee member)

Then run `verify_policies.sql`: every row should say PASS. Run it again after any database change. Most scripts are safe to run twice.

## Making a change

1. Edit the file on GitHub (or upload a replacement). Cloudflare Pages publishes within a minute or two.
2. Check the page on a phone and a computer, signed out and signed in.
3. If something breaks, in Cloudflare open Deployments, choose the last good one and press Rollback.

Please protect `main` (Settings, Branches) and keep two-factor sign-in on the GitHub, Cloudflare and Supabase accounts.

## Backups

See [BACKUP_AND_RESTORE.md](BACKUP_AND_RESTORE.md). In short: committee members download an encrypted backup monthly from the Committee area, and a full Supabase dump is taken every three months.

## Who to ask

The club committee: rjdarchers.members@gmail.com

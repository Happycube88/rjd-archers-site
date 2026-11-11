# RJD Archers – backup and restore

## What lives where
| Thing | Where | Backed up by |
|---|---|---|
| Website files | GitHub `Happycube88/rjd-archers-site` | GitHub itself + a monthly ZIP (below) |
| Live site | Cloudflare Pages `rjd` | Every deploy is kept: Deployments > pick an old one > Rollback |
| Data (members, scores, entries, nights) | Supabase project `RJD` | **You** – the free plan has no automatic backups |
| Database structure and rules | `sql/` folder in this repo | The repo |
| Secrets (Supabase keys, SMTP password) | Supabase / Cloudflare dashboards | Keep a copy in a password manager. Never put in GitHub |

## Database – the routine (monthly, and after big changes)
1. **Quick copy:** sign in at /committee.html, use 2FA, open *Download a backup*, press *Create the backup*, then *Download everything*. Store the file on an encrypted drive. It contains personal data including children's details: never email it, delete old copies.
2. **Full copy (recommended, 10 minutes, every 3 months):** with the Supabase CLI and the database connection string (Supabase > Connect > Session pooler):
   `supabase db dump --db-url "postgresql://..." -f structure.sql`
   `supabase db dump --db-url "postgresql://..." --data-only -f data.sql`
   This also captures user logins' links, which the in-app copy does not. Keep both files with the quick copy.
3. Keep **three** copies in **two** places (e.g. committee laptop + encrypted cloud folder), one at least a month old.
4. Safer option: upgrade Supabase to Pro (daily automatic backups kept 7 days; point-in-time recovery is a paid add-on). Worth it once the club relies on online entries.
5. **Test a restore once a year** into a free scratch Supabase project, so you know it works.

## Restoring the database
- Whole project lost: create a new Supabase project, run the `sql/` files in this order: schema, security_migration, members_family, committee_edit_and_badges, badge_252, rounds_and_linking, fix_grants, guests, tournaments, club_nights, club_night_schedule, then load `data.sql` (`psql "<connection string>" -f data.sql`), then run `verify_policies.sql` (every row should say pass). Update the project URL and anon key in the pages and in Cloudflare.
- A table damaged: restore just that table from the JSON file (ask your helper, or load the rows with an INSERT script).
- Members must sign in again by email link and re-enrol 2FA if logins were not restored.

## Code
- GitHub is the master copy. Turn on branch protection for `main` (Settings > Branches) and 2FA on your GitHub account.
- Once a month: Code > Download ZIP, store with the data backup.
- A bad upload: Cloudflare Pages > Deployments > the last good one > Rollback, or revert the commit in GitHub.
- Do not put keys, passwords or backup files in the repo (it is public).

## Calendar reminder
First Sunday of each month: quick copy. Quarterly: full copy + ZIP. Yearly: test restore.

## Where to keep the copies (free)
- The club Google account (rjdarchers.members@gmail.com) has 15 GB of free Google Drive: make a private folder called `RJD backups`, never share it, and turn on 2-step verification for that Google account.
- Put only locked `.rjdbak` files and the SQL dump (zip it with a password, e.g. 7-Zip AES) there. Google can read ordinary Drive files, so locking them first matters.
- Keep a second copy on a committee member's own computer or encrypted USB stick, so one lost account does not lose everything.
- Keep the last 12 monthly copies and delete older ones.

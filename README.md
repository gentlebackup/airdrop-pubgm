# AIRDROP PUBGM

A PUBG Mobile community and competition hub built as an independent platform.

## Stack
- Next.js 16 / React 19
- Supabase Auth, Postgres, Storage and Realtime
- Vercel deployment

## Fresh Supabase setup
1. Use only the separate AIRDROP PUBGM Supabase project.
2. Open the SQL Editor in that project.
3. Open [supabase/AIRDROP-PUBGM-SETUP.sql](supabase/AIRDROP-PUBGM-SETUP.sql), copy the complete SQL, and run it once.
4. Do not run the older files in `supabase/migrations/` individually. They are retained as source/reference migrations; the consolidated setup file contains the selected baseline and compatible feature schema.
5. Run [supabase/VERIFY-AIRDROP-PUBGM.sql](supabase/VERIFY-AIRDROP-PUBGM.sql) to perform read-only checks.
6. Follow [docs/ADMIN-BOOTSTRAP.md](docs/ADMIN-BOOTSTRAP.md) to grant the first owner role after creating your player account.
7. Complete end-to-end checks before connecting the app to Vercel.

## Important safety notes
- Never connect this repository to the old CODM Supabase project.
- Do not copy old player accounts, wallet balances, purchase records, withdrawals, messages or social posts.
- The consolidated setup creates core identity, activity, tournament, feed, community, wallet-schema, progression and restricted admin-review foundations. It does **not** mean every app feature is finished or tested yet.
- Credit purchase requests and admin review RPCs are present, but payment approval must remain disabled until the receiving bank details and manual reconciliation process are configured and tested. Cash withdrawals remain disabled; their RPCs explicitly refuse processing. Mission-level cash claims are also disabled until reward amounts are deliberately configured.
- Cash withdrawals and credit purchases remain disabled by default. Do not manually enable either setting before the review workflows and payment controls are complete.
- Do not add a Supabase service-role key to the website or GitHub.

## Automated build check

GitHub Actions runs `npm ci` and `npm run build` on app and dependency changes. Check the **AIRDROP PUBGM Build Check** workflow before deployment.

## Local setup
1. Install Node.js 20.
2. Run `npm install`.
3. Copy `.env.example` to `.env.local`.
4. Set `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` using the new project's values.
5. Run `npm run dev`.

## First admin account

Follow [docs/ADMIN-BOOTSTRAP.md](docs/ADMIN-BOOTSTRAP.md) to grant the `owner` role to your own account after it has been created. The project intentionally creates no administrator automatically.

## Deploy to Vercel
Wait until the database and app checks are complete. Then import this repository in Vercel, select the Next.js framework preset, and add the two public environment variables above. Do not connect Vercel until the project owner explicitly approves.

## PUBG Mobile configuration
The app branding and profile game ID are PUBG Mobile-specific. Configure the new Supabase OAuth redirect URLs and Capacitor deep link as `airdroppubgm://auth/callback` if native builds are used.

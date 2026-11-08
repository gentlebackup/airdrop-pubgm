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
5. After the schema is installed, finish the remaining RPC functions and admin bootstrap steps before connecting the app to Vercel.

## Important safety notes
- Never connect this repository to the old CODM Supabase project.
- Do not copy old player accounts, wallet balances, purchase records, withdrawals, messages or social posts.
- The consolidated setup creates core identity, activity, tournament, feed, community, wallet-schema and progression tables. It does **not** mean every app feature is finished yet.
- Credit purchase approvals, cash withdrawals, tournament result approvals and several admin workflows still require their dedicated secure RPCs and end-to-end testing.
- Cash withdrawals and credit purchases remain disabled by default. Do not manually enable either setting before the review workflows and payment controls are complete.
- Do not add a Supabase service-role key to the website or GitHub.

## Local setup
1. Install Node.js 20.
2. Run `npm install`.
3. Copy `.env.example` to `.env.local`.
4. Set `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` using the new project's values.
5. Run `npm run dev`.

## Deploy to Vercel
Wait until the database and app checks are complete. Then import this repository in Vercel, select the Next.js framework preset, and add the two public environment variables above. Do not connect Vercel until the project owner explicitly approves.

## PUBG Mobile configuration
The app branding and profile game ID are PUBG Mobile-specific. Configure the new Supabase OAuth redirect URLs and Capacitor deep link as `airdroppubgm://auth/callback` if native builds are used.

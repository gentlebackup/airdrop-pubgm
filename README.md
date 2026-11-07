# AIRDROP PUBGM

A PUBG Mobile community and competition hub built as an independent PUBG Mobile community and competition platform.

## Stack
- Next.js 16 / React 19
- Supabase Auth, Postgres, Storage and Realtime
- Vercel deployment

## Local setup
1. Install Node.js 20.
2. Run `npm install`.
3. Copy `.env.example` to `.env.local`.
4. Create a **new** Supabase project and set `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`.
5. Apply the SQL in `supabase/migrations/` to the new project after the required base schema is available.
6. Run `npm run dev`.

## Important backend note
The supplied source archive contains incremental security and feature migrations, not a complete first-time database schema. The web app has been disconnected from the original Supabase project, and the original URL/key are not included here. A fresh Supabase project still needs a complete baseline schema and matching RPC functions before login, tournaments, wallets, social features, and admin tools can operate. Do not connect this site to the old Cloud CODM Supabase project.

## Deploy to Vercel
Import this repository in Vercel, choose the Next.js framework preset, and add the two environment variables above. Redeploy after adding them.

## PUBG Mobile configuration
The app branding and profile game ID are now PUBG Mobile-specific. Configure the new Supabase OAuth redirect URLs and Capacitor deep link as `airdroppubgm://auth/callback` if native builds are used.

# AIRDROP PUBGM

PUBG Mobile community and tournament platform.

## Current stage

The GitHub repository is being prepared first. Vercel deployment is intentionally on hold until you say you're ready.

Follow [the source import instructions](docs/IMPORT-SOURCE.md) to add the complete prepared application source. A GitHub Actions workflow will extract the uploaded ZIP into the repository root.

## Later setup (when you're ready)

1. Import this repository into a **new** Vercel project.
2. Create a completely separate Supabase project for AIRDROP PUBGM.
3. Configure `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` using that new Supabase project.
4. Complete the initial database schema and required RPC functions before enabling authentication, tournaments, wallet, feed, or other backend features.

Do not connect this project to the database used by the older CODM website.

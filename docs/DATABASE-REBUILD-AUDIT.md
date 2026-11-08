# AIRDROP PUBGM database rebuild audit

Status: design/audit only. This document is not executable SQL.

## Source material reviewed
- AIRDROP PUBGM source ZIP imported into this repository.
- App REST table usage and RPC calls in app/page.js and app/admin/page.js.
- Ten existing incremental SQL migrations in supabase/migrations/.
- Old CODM public-schema inventory supplied by the project owner: 394 columns across the existing public tables.
- Old CODM function inventory and the definitions supplied for handle_new_user() and create_activity().

## Isolation requirements
- AIRDROP PUBGM must use its own Supabase project only.
- Do not copy auth.users, player profiles, wallet balances, purchase records, withdrawal records, messages, posts, or other user data from CODM.
- Never use the old CODM URL, anon/publishable key, service-role key, or database password in this repository or the new project.
- The old CODM project is a read-only reference. No changes are to be applied there.

## Application dependencies found
The app calls RPCs for activity/challenge creation, joining, check-in, participation confirmation and rewards, activity secrets, activity editing/cancellation, tournament seeding/results, player progression/achievements, profile cosmetics/missions, credit purchase requests, withdrawals, feed retrieval/views, and admin review/moderation.

The app also reads/writes profile, activity, participant, challenge, notification, player verification, mission, cosmetic, tournament, wallet/ledger, withdrawal, purchase, social-feed, messaging, follow/block/report, live-stream, site-media and admin-role tables.

## Important migration finding
The ten SQL files currently in supabase/migrations/ are incremental feature/security migrations, not a complete first-install schema. Some explicitly say development-only or require review before production. They must not be treated as a complete fresh-project setup or blindly applied without a compatible baseline.

## Rebuild strategy
1. Create a first-install baseline migration that defines the required enums, tables, constraints, indexes, triggers, RLS policies and storage buckets for a brand-new AIRDROP PUBGM Supabase project.
2. Recreate app-facing RPCs using the actual app call signatures and the security intent of the reviewed migrations.
3. Review every SECURITY DEFINER function, pin search_path, validate auth.uid(), restrict EXECUTE grants, and ensure wallet/credit changes are atomic and ledger-backed.
4. Adapt CODM-specific profile fields, labels, notification text and media defaults to PUBG Mobile.
5. Apply migrations only to the new AIRDROP PUBGM Supabase project after static review and a clean-project test.
6. Verify signup/profile creation, activity creation/joining, 1v1 challenges, tournament brackets/results, social feed, moderation, credit purchase requests and withdrawal workflows before deployment.

## Known limitations to resolve during implementation
- The source ZIP does not contain the complete original first-install schema.
- The inventory of columns does not include all primary keys, foreign keys, check constraints, indexes, enum labels, triggers, RLS policies or full stored-function bodies.
- Only selected original function bodies were supplied. Other RPCs must be reconstructed from the app's call signatures and the reviewed migration logic; they must not be represented as verbatim copies of the CODM implementation.
- No migration has been run against the new Supabase project. The project remains separate and untouched by this audit.
- Vercel must remain disconnected until the database is reviewed and the owner explicitly says to proceed.

## Safety decisions
- Do not add a client-accessible path that directly edits purchased credits, reward credits, token balances, payout settings, or withdrawal status.
- Keep room codes/passwords in a separately protected activity_secrets table and expose them only through an authorized RPC.
- Keep profiles private by default; expose only approved discovery fields through public_profiles.
- Keep cash withdrawals disabled by default until payout settings and manual-review controls are explicitly configured and tested.

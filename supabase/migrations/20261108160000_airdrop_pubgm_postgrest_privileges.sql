-- AIRDROP PUBGM — explicit PostgREST table privileges
-- Phase 8. Keeps ordinary app reads available while protected writes stay RPC-only.

begin;

grant select on public.profiles,public.public_profiles,public.activities,
 public.participants,public.challenges_1v1,public.notifications,public.admin_roles
 to authenticated;
grant update(read_at) on public.notifications to authenticated;

-- Profile edits are limited to public/profile fields. Wallets and equipped system
-- fields are changed only by SECURITY DEFINER RPCs.
revoke update on public.profiles from anon,authenticated;
grant update(profile_name,username,region,phone,game_name,pubgm_game_id,avatar_url)
 on public.profiles to authenticated;

revoke insert,update,delete on public.activities,public.participants,public.challenges_1v1,
 public.notifications,public.public_profiles from anon,authenticated;

commit;

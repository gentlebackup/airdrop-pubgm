-- AIRDROP PUBGM: restrict private SECURITY DEFINER RPC entry points.
-- Keep public_player_showcase() callable by anon; it intentionally exposes
-- only the selected fields for profiles opted into public visibility.

begin;

revoke execute on function public.admin_list_players() from public, anon;
revoke execute on function public.admin_profile_mission_entries() from public, anon;
revoke execute on function public.admin_profile_mission_level_claims() from public, anon;
revoke execute on function public.admin_review_profile_mission_entry(uuid, text, text) from public, anon;
revoke execute on function public.admin_review_profile_mission_level_claim(uuid, text, text) from public, anon;
revoke execute on function public.admin_review_profile_mission_level_claim(uuid, text, text, text) from public, anon;
revoke execute on function public.claim_profile_mission_level(integer) from public, anon;
revoke execute on function public.equip_profile_mission_cosmetic(integer) from public, anon;
revoke execute on function public.get_credit_purchase_settings() from public, anon;
revoke execute on function public.refresh_profile_mission_entries() from public, anon;
revoke execute on function public.request_withdrawal(integer, text, text, text) from public, anon;

grant execute on function public.admin_list_players() to authenticated, service_role;
grant execute on function public.admin_profile_mission_entries() to authenticated, service_role;
grant execute on function public.admin_profile_mission_level_claims() to authenticated, service_role;
grant execute on function public.admin_review_profile_mission_entry(uuid, text, text) to authenticated, service_role;
grant execute on function public.admin_review_profile_mission_level_claim(uuid, text, text) to authenticated, service_role;
grant execute on function public.admin_review_profile_mission_level_claim(uuid, text, text, text) to authenticated, service_role;
grant execute on function public.claim_profile_mission_level(integer) to authenticated, service_role;
grant execute on function public.equip_profile_mission_cosmetic(integer) to authenticated, service_role;
grant execute on function public.get_credit_purchase_settings() to authenticated, service_role;
grant execute on function public.refresh_profile_mission_entries() to authenticated, service_role;
grant execute on function public.request_withdrawal(integer, text, text, text) to authenticated, service_role;

commit;

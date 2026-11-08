-- AIRDROP PUBGM — enrich the admin mission-claim queue with safe profile labels

begin;
drop function if exists public.admin_profile_mission_level_claims();
create function public.admin_profile_mission_level_claims()
returns table(
 id uuid,user_id uuid,level integer,required_activities integer,cash_reward_usd numeric,
 status text,reviewed_by uuid,reviewed_at timestamptz,paid_at timestamptz,
 reviewer_note text,created_at timestamptz,collectible_code text,claimed_at timestamptz,
 payout_reference text,profile_name text,username text
)
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform public._airdrop_require_admin(false);
 return query
 select c.id,c.user_id,c.level,c.required_activities,c.cash_reward_usd,c.status,
  c.reviewed_by,c.reviewed_at,c.paid_at,c.reviewer_note,c.created_at,
  c.collectible_code,c.claimed_at,c.payout_reference,p.profile_name,p.username
 from public.profile_mission_level_claims c
 join public.profiles p on p.id=c.user_id
 order by c.created_at asc;
end $$;
revoke all on function public.admin_profile_mission_level_claims() from public,anon;
grant execute on function public.admin_profile_mission_level_claims() to authenticated;
commit;

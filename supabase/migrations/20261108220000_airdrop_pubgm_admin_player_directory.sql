-- AIRDROP PUBGM — admin player directory RPC
-- Required by the existing admin dashboard's Players & Credits view.

begin;

create or replace function public.admin_list_players()
returns table(
 id uuid,
 profile_name text,
 username text,
 created_at timestamptz,
 purchased_credits integer,
 reward_credits integer
)
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform public._airdrop_require_admin(false);
 return query
 select p.id,p.profile_name,p.username,p.created_at,p.purchased_credits,p.reward_credits
 from public.profiles p
 order by p.created_at desc;
end $$;

revoke all on function public.admin_list_players() from public,anon;
grant execute on function public.admin_list_players() to authenticated;

commit;

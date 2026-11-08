-- AIRDROP PUBGM — progression, leaderboard, cosmetics and purchase-request RPCs
-- Phase 6. Payment remains manual and disabled by default.

begin;

insert into public.seasons(name,starts_at,ends_at,status)
select 'Launch Season',now(),now()+interval '365 days','active'
where not exists(select 1 from public.seasons where status='active');

create or replace function public.current_season()
returns public.seasons language sql stable security definer set search_path=public,pg_temp as $$
 select * from public.seasons where status='active' order by starts_at desc limit 1;
$$;

create or replace function public.refresh_player_progression(p_user_id uuid)
returns public.player_progression language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); sid uuid; result public.player_progression;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if p_user_id is distinct from uid and not exists(select 1 from public.admin_roles where user_id=uid and role in('admin','super_admin','owner')) then raise exception 'Not authorized'; end if;
 select id into sid from public.seasons where status='active' order by starts_at desc limit 1;
 if sid is null then raise exception 'No active season is configured'; end if;
 insert into public.player_progression(user_id,season_id,xp,level)
 values(p_user_id,sid,0,1)
 on conflict(user_id,season_id) do nothing;
 select * into result from public.player_progression where user_id=p_user_id and season_id=sid;
 return result;
end $$;

create or replace function public.player_leaderboard(p_limit integer default 100)
returns table(rank bigint,user_id uuid,profile_name text,username text,region text,avatar_url text,xp integer,level integer,matches_completed integer,tournaments_joined integer,achievements_unlocked bigint,profile_frame_style_key text)
language sql stable security definer set search_path=public,pg_temp as $$
 with active_season as (
  select id from public.seasons where status='active' order by starts_at desc limit 1
 ), ranked as (
  select pp.id as user_id,pp.profile_name,pp.username,pp.region,pp.avatar_url,
   coalesce(pr.xp,0)::integer as xp,coalesce(pr.level,1)::integer as level,
   coalesce(st.matches_completed,0)::integer as matches_completed,
   coalesce(st.tournaments_joined,0)::integer as tournaments_joined,
   (select count(*) from public.user_achievements ua where ua.user_id=pp.id)::bigint as achievements_unlocked,
   coalesce(frame.style_key,'') as profile_frame_style_key
  from public.public_profiles pp
  left join active_season s on true
  left join public.player_progression pr on pr.user_id=pp.id and pr.season_id=s.id
  left join public.user_activity_stats st on st.user_id=pp.id
  left join public.profile_cosmetics frame on frame.id=(select equipped_profile_frame_id from public.profiles where id=pp.id)
 )
 select row_number() over(order by xp desc,level desc,matches_completed desc,user_id),
        user_id,profile_name,username,region,avatar_url,xp,level,matches_completed,tournaments_joined,achievements_unlocked,profile_frame_style_key
 from ranked order by xp desc,level desc,matches_completed desc,user_id
 limit greatest(1,least(coalesce(p_limit,100),200));
$$;

create or replace function public.public_player_showcase(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
 if p_user_id is null then raise exception 'Player ID is required'; end if;
 select jsonb_build_object(
  'xp',coalesce(pr.xp,0),'level',coalesce(pr.level,1),
  'matches_completed',coalesce(st.matches_completed,0),
  'tournaments_joined',coalesce(st.tournaments_joined,0),
  'achievements_unlocked',(select count(*) from public.user_achievements ua where ua.user_id=p_user_id),
  'profile_frame_style_key',coalesce(frame.style_key,'')
 ) into result
 from public.profiles p
 left join public.seasons s on s.status='active'
 left join public.player_progression pr on pr.user_id=p.id and pr.season_id=s.id
 left join public.user_activity_stats st on st.user_id=p.id
 left join public.profile_cosmetics frame on frame.id=p.equipped_profile_frame_id
 where p.id=p_user_id;
 if result is null then raise exception 'Player not found'; end if;
 return result;
end $$;

create or replace function public.refresh_user_achievements(p_user_id uuid)
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); inserted_count integer;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if p_user_id is distinct from uid and not exists(select 1 from public.admin_roles where user_id=uid and role in('admin','super_admin','owner')) then raise exception 'Not authorized'; end if;
 insert into public.user_achievements(user_id,achievement_id)
 select p_user_id,a.id from public.achievements a
 left join public.user_activity_stats st on st.user_id=p_user_id
 where
  (a.requirement_type='matches_completed' and coalesce(st.matches_completed,0)>=a.requirement_value)
  or (a.requirement_type='tournaments_joined' and coalesce(st.tournaments_joined,0)>=a.requirement_value)
  or (a.requirement_type='tournaments_created' and coalesce(st.tournaments_created,0)>=a.requirement_value)
  or (a.requirement_type='challenges_completed' and coalesce(st.challenges_completed,0)>=a.requirement_value)
 on conflict(user_id,achievement_id) do nothing;
 get diagnostics inserted_count=row_count;
 return inserted_count;
end $$;

create or replace function public.my_achievements()
returns table(code text,name text,description text,icon text,unlocked_at timestamptz)
language sql stable security definer set search_path=public,pg_temp as $$
 select a.code,a.name,a.description,a.icon,ua.unlocked_at
 from public.user_achievements ua join public.achievements a on a.id=ua.achievement_id
 where ua.user_id=auth.uid() order by ua.unlocked_at desc;
$$;

create or replace function public.refresh_profile_mission_entries()
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); inserted_count integer;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 insert into public.profile_mission_entries(user_id,activity_id,participant_id,entry_fee_credits)
 select p.user_id,p.activity_id,p.id,a.entry_fee_credits
 from public.participants p join public.activities a on a.id=p.activity_id
 where p.user_id=uid and p.status in('confirmed','completed') and a.entry_fee_credits>0
 on conflict(user_id,activity_id) do nothing;
 get diagnostics inserted_count=row_count;
 return inserted_count;
end $$;

create or replace function public.get_credit_purchase_settings()
returns table(receiving_bank_name text,receiving_account_name text,receiving_account_number text,enabled boolean)
language sql stable security definer set search_path=public,pg_temp as $$
 select s.receiving_bank_name,s.receiving_account_name,s.receiving_account_number,s.enabled
 from public.credit_purchase_settings s where s.id=true;
$$;

create or replace function public.create_credit_purchase_request(p_package_credits integer,p_transfer_reference text default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); rid uuid; enabled_value boolean;
begin
 if uid is null then raise exception 'Sign in to request a credit purchase.'; end if;
 select enabled into enabled_value from public.credit_purchase_settings where id=true;
 if not coalesce(enabled_value,false) then raise exception 'Credit purchases are not open yet. Please try again later.'; end if;
 if p_package_credits not in(1,2,3,4,5,6,7,8,9,10,20,30,50,60,80,100,150,200,250,300) then raise exception 'Choose one of the available credit packages.'; end if;
 if exists(select 1 from public.credit_purchase_requests where user_id=uid and status in('pending','under_review')) then raise exception 'You already have a purchase request awaiting review'; end if;
 insert into public.credit_purchase_requests(user_id,package_credits,amount_ngn,transfer_reference)
 values(uid,p_package_credits,p_package_credits*1300,nullif(trim(p_transfer_reference),'')) returning id into rid;
 return rid;
end $$;

create or replace function public.buy_profile_cosmetic(p_cosmetic_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); c public.profile_cosmetics; item_id uuid;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into c from public.profile_cosmetics where id=p_cosmetic_id and active=true;
 if not found then raise exception 'Cosmetic is unavailable'; end if;
 if exists(select 1 from public.profile_cosmetic_inventory where user_id=uid and cosmetic_id=c.id) then raise exception 'You already own this cosmetic'; end if;
 update public.profiles set purchased_credits=purchased_credits-c.price_credits,updated_at=now()
 where id=uid and purchased_credits>=c.price_credits;
 if not found then raise exception 'Insufficient purchased credits'; end if;
 insert into public.profile_cosmetic_inventory(user_id,cosmetic_id) values(uid,c.id) returning id into item_id;
 insert into public.creation_token_transactions(user_id,amount,reason) values(uid,-c.price_credits,'profile_cosmetic_purchase');
 return item_id;
end $$;

create or replace function public.equip_store_profile_cosmetic(p_cosmetic_id uuid,p_category text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); c public.profile_cosmetics;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if p_cosmetic_id is null then
  update public.profiles set
   equipped_store_cosmetic_id=case when p_category='store' then null else equipped_store_cosmetic_id end,
   equipped_name_style_cosmetic_id=case when p_category='name_style' then null else equipped_name_style_cosmetic_id end,
   equipped_profile_frame_id=case when p_category='profile_frame' then null else equipped_profile_frame_id end,
   equipped_profile_theme_id=case when p_category='profile_theme' then null else equipped_profile_theme_id end,
   equipped_avatar_effect_id=case when p_category='avatar_effect' then null else equipped_avatar_effect_id end,
   updated_at=now() where id=uid;
  return;
 end if;
 select * into c from public.profile_cosmetics where id=p_cosmetic_id and active=true and category=p_category;
 if not found then raise exception 'Cosmetic does not match the selected category'; end if;
 if not exists(select 1 from public.profile_cosmetic_inventory where user_id=uid and cosmetic_id=c.id) then raise exception 'Purchase this cosmetic before equipping it'; end if;
 update public.profiles set
  equipped_store_cosmetic_id=case when p_category='store' then c.id else equipped_store_cosmetic_id end,
  equipped_name_style_cosmetic_id=case when p_category='name_style' then c.id else equipped_name_style_cosmetic_id end,
  equipped_profile_frame_id=case when p_category='profile_frame' then c.id else equipped_profile_frame_id end,
  equipped_profile_theme_id=case when p_category='profile_theme' then c.id else equipped_profile_theme_id end,
  equipped_avatar_effect_id=case when p_category='avatar_effect' then c.id else equipped_avatar_effect_id end,
  updated_at=now() where id=uid;
end $$;

revoke all on function public.current_season() from public,anon;
revoke all on function public.refresh_player_progression(uuid) from public,anon;
revoke all on function public.player_leaderboard(integer) from public,anon;
revoke all on function public.public_player_showcase(uuid) from public,anon;
revoke all on function public.refresh_user_achievements(uuid) from public,anon;
revoke all on function public.my_achievements() from public,anon;
revoke all on function public.refresh_profile_mission_entries() from public,anon;
revoke all on function public.get_credit_purchase_settings() from public,anon;
revoke all on function public.create_credit_purchase_request(integer,text) from public,anon;
revoke all on function public.buy_profile_cosmetic(uuid) from public,anon;
revoke all on function public.equip_store_profile_cosmetic(uuid,text) from public,anon;
grant execute on function public.current_season() to authenticated;
grant execute on function public.refresh_player_progression(uuid) to authenticated;
grant execute on function public.player_leaderboard(integer) to authenticated;
grant execute on function public.public_player_showcase(uuid) to authenticated;
grant execute on function public.refresh_user_achievements(uuid) to authenticated;
grant execute on function public.my_achievements() to authenticated;
grant execute on function public.refresh_profile_mission_entries() to authenticated;
grant execute on function public.get_credit_purchase_settings() to authenticated;
grant execute on function public.create_credit_purchase_request(integer,text) to authenticated;
grant execute on function public.buy_profile_cosmetic(uuid) to authenticated;
grant execute on function public.equip_store_profile_cosmetic(uuid,text) to authenticated;

commit;

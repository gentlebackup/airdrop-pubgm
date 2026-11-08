-- AIRDROP PUBGM — mission-level configuration and collectible equip RPCs
-- Mission cash claims stay inactive until the owner explicitly configures reward amounts.

begin;

create table if not exists public.profile_mission_level_settings (
 level integer primary key check(level between 1 and 10),
 required_free_activities integer not null check(required_free_activities>=0),
 required_paid_activities integer not null check(required_paid_activities>=0),
 required_activities integer not null check(required_activities>=1),
 cash_reward_usd numeric(12,2) not null default 0 check(cash_reward_usd>=0),
 collectible_code text,
 enabled boolean not null default false
);
alter table public.profile_mission_level_settings enable row level security;
drop policy if exists mission_level_settings_read_authenticated on public.profile_mission_level_settings;
create policy mission_level_settings_read_authenticated on public.profile_mission_level_settings for select to authenticated using(true);
grant select on public.profile_mission_level_settings to authenticated;
revoke insert,update,delete on public.profile_mission_level_settings from anon,authenticated;

insert into public.profile_mission_level_settings(level,required_free_activities,required_paid_activities,required_activities,cash_reward_usd,collectible_code,enabled)
values
 (1,1,1,2,0,'mission_level_1',false),
 (2,3,2,5,0,'mission_level_2',false),
 (3,5,4,9,0,'mission_level_3',false),
 (4,7,6,13,0,'mission_level_4',false),
 (5,9,9,18,0,'mission_level_5',false),
 (6,12,12,24,0,'mission_level_6',false),
 (7,16,15,31,0,'mission_level_7',false),
 (8,20,19,39,0,'mission_level_8',false),
 (9,25,23,48,0,'mission_level_9',false),
 (10,33,25,58,0,'mission_level_10',false)
on conflict(level) do nothing;

create or replace function public.claim_profile_mission_level(p_level integer)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
 uid uuid:=auth.uid(); cfg public.profile_mission_level_settings; free_count integer; paid_count integer; claim_id uuid;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if p_level not between 1 and 10 then raise exception 'Invalid mission level'; end if;
 select * into cfg from public.profile_mission_level_settings where level=p_level and enabled=true;
 if not found then return null; end if;
 select count(*) filter(where entry_fee_credits=0),count(*) filter(where entry_fee_credits>0)
 into free_count,paid_count
 from public.profile_mission_entries where user_id=uid and status='approved';
 if free_count<cfg.required_free_activities or paid_count<cfg.required_paid_activities then
  raise exception 'You have not completed the verified activities required for this level';
 end if;
 insert into public.profile_mission_level_claims(user_id,level,required_activities,cash_reward_usd,status,collectible_code,claimed_at)
 values(uid,p_level,cfg.required_activities,cfg.cash_reward_usd,'pending_admin_review',cfg.collectible_code,now())
 on conflict(user_id,level) do nothing returning id into claim_id;
 if claim_id is null then select id into claim_id from public.profile_mission_level_claims where user_id=uid and level=p_level; end if;
 return claim_id;
end $$;

create or replace function public.equip_profile_mission_cosmetic(p_level integer)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if coalesce(p_level,0)=0 then
  update public.profiles set equipped_mission_level=null,updated_at=now() where id=uid;
  return;
 end if;
 if p_level not between 1 and 10 then raise exception 'Invalid collectible level'; end if;
 if not exists(select 1 from public.profile_mission_level_claims where user_id=uid and level=p_level and status in('approved_for_payout','paid')) then
  raise exception 'This mission collectible has not been approved yet';
 end if;
 update public.profiles set equipped_mission_level=p_level,updated_at=now() where id=uid;
end $$;

-- Free and paid verified activity completions both count toward profile missions.
create or replace function public.refresh_profile_mission_entries()
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); inserted_count integer;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 insert into public.profile_mission_entries(user_id,activity_id,participant_id,entry_fee_credits)
 select p.user_id,p.activity_id,p.id,a.entry_fee_credits
 from public.participants p join public.activities a on a.id=p.activity_id
 where p.user_id=uid and p.status in('confirmed','completed')
 on conflict(user_id,activity_id) do nothing;
 get diagnostics inserted_count=row_count;
 return inserted_count;
end $$;

revoke all on function public.claim_profile_mission_level(integer) from public,anon;
revoke all on function public.equip_profile_mission_cosmetic(integer) from public,anon;
grant execute on function public.claim_profile_mission_level(integer) to authenticated;
grant execute on function public.equip_profile_mission_cosmetic(integer) to authenticated;

commit;

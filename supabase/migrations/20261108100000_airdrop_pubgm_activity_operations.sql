-- AIRDROP PUBGM — activity, challenge and participation operations
-- Phase 2. Depends on 20261108090000_airdrop_pubgm_core_foundation.sql.
-- Credit debits and reward grants are atomic and ledger-backed.

begin;

create table if not exists public.reward_credit_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null,
  reason text not null,
  activity_id uuid references public.activities(id) on delete set null,
  participant_id uuid references public.participants(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists reward_credit_transactions_user_idx
  on public.reward_credit_transactions(user_id,created_at desc);

create table if not exists public.admin_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check(role in ('admin','moderator','super_admin','owner')),
  created_at timestamptz not null default now(),
  primary key(user_id,role)
);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  activity_id uuid not null references public.activities(id) on delete cascade,
  reported_user_id uuid references auth.users(id) on delete set null,
  category text not null,
  details text,
  status text not null default 'open' check(status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now()
);

create or replace function public.create_activity(
  p_type public.activity_type,p_title text,p_room_code text,p_room_password text,
  p_scheduled_start timestamptz,p_duration_minutes integer,p_capacity integer,
  p_game_mode text default null,p_map_name text default null,p_rules text default null
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); aid uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if coalesce(length(trim(p_title)),0)<3 then raise exception 'Activity title is required'; end if;
  if p_duration_minutes is null or p_duration_minutes not between 1 and 720 then raise exception 'Activity duration is invalid'; end if;
  if p_capacity is null or p_capacity not between 2 and 100 then raise exception 'Activity capacity is invalid'; end if;
  if p_type='tournament' and p_capacity not in (4,8,16,32) then raise exception 'Tournament capacity must be 4, 8, 16 or 32 players'; end if;
  if p_scheduled_start is null or p_scheduled_start<=now() then raise exception 'Start time must be in the future'; end if;
  if coalesce(length(trim(p_room_code)),0)=0 then raise exception 'Room code is required'; end if;

  update public.profiles set purchased_credits=purchased_credits-1,updated_at=now()
  where id=uid and purchased_credits>=1;
  if not found then raise exception 'Creating an activity costs 1 purchased credit. Please add credits to your wallet.'; end if;

  insert into public.activities(creator_id,type,title,scheduled_start,duration_minutes,capacity,game_mode,map_name,rules,entry_fee_credits)
  values(uid,p_type,trim(p_title),p_scheduled_start,p_duration_minutes,p_capacity,left(p_game_mode,80),left(p_map_name,80),left(p_rules,2000),1)
  returning id into aid;
  insert into public.activity_secrets(activity_id,room_code,room_password)
  values(aid,trim(p_room_code),nullif(trim(p_room_password),''));
  insert into public.creation_token_transactions(user_id,amount,reason,activity_id)
  values(uid,-1,'credit_spent_activity_creation',aid);
  return aid;
end $$;

create or replace function public.create_1v1_challenge(
 p_opponent_id uuid,p_title text,p_room_code text,p_room_password text,
 p_scheduled_start timestamptz,p_duration_minutes integer,
 p_game_mode text default null,p_map_name text default null,p_rules text default null
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); aid uuid;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if p_opponent_id is null or p_opponent_id=uid then raise exception 'Choose a different opponent'; end if;
 if not exists(select 1 from public.profiles where id=p_opponent_id) then raise exception 'Opponent not found'; end if;
 if coalesce(length(trim(p_title)),0)<3 then raise exception 'Challenge title is required'; end if;
 if p_duration_minutes is null or p_duration_minutes not between 1 and 720 then raise exception 'Challenge duration is invalid'; end if;
 if p_scheduled_start is null or p_scheduled_start<=now() then raise exception 'Start time must be in the future'; end if;
 if coalesce(length(trim(p_room_code)),0)=0 then raise exception 'Room code is required'; end if;

 update public.profiles set purchased_credits=purchased_credits-1,updated_at=now()
 where id=uid and purchased_credits>=1;
 if not found then raise exception 'Creating a 1v1 challenge costs 1 purchased credit. Please add credits to your wallet.'; end if;

 insert into public.activities(creator_id,type,title,scheduled_start,duration_minutes,capacity,game_mode,map_name,rules,entry_fee_credits)
 values(uid,'challenge_1v1',trim(p_title),p_scheduled_start,p_duration_minutes,2,left(p_game_mode,80),left(p_map_name,80),left(p_rules,2000),1)
 returning id into aid;
 insert into public.activity_secrets(activity_id,room_code,room_password)
 values(aid,trim(p_room_code),nullif(trim(p_room_password),''));
 insert into public.challenges_1v1(activity_id,challenger_id,opponent_id,status)
 values(aid,uid,p_opponent_id,'pending');
 insert into public.creation_token_transactions(user_id,amount,reason,activity_id)
 values(uid,-1,'credit_spent_activity_creation',aid);
 return aid;
end $$;

create or replace function public.set_activity_entry_fee(p_activity_id uuid,p_entry_fee_credits integer)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); is_admin boolean;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if p_entry_fee_credits is distinct from 1 then raise exception 'The entry fee is fixed at 1 credit per participant.'; end if;
 select exists(select 1 from public.admin_roles where user_id=uid and role in('admin','super_admin','owner')) into is_admin;
 update public.activities a set entry_fee_credits=1,updated_at=now()
 where a.id=p_activity_id and (a.creator_id=uid or is_admin) and a.status='upcoming'
 and not exists(select 1 from public.participants p where p.activity_id=a.id);
 if not found then raise exception 'Only the creator or an administrator can set the fixed price before anyone joins an upcoming activity'; end if;
end $$;

create or replace function public.join_activity(p_activity_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); a public.activities; pid uuid; balance integer;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into a from public.activities where id=p_activity_id for update;
 if not found then raise exception 'Activity not found'; end if;
 if a.status not in('upcoming','check_in') or a.scheduled_start+a.duration_minutes*interval '1 minute'<=now() then raise exception 'This activity is no longer accepting players'; end if;
 if a.creator_id=uid then raise exception 'The activity creator is already registered as host'; end if;
 if exists(select 1 from public.participants where activity_id=p_activity_id and user_id=uid) then raise exception 'You have already joined this activity'; end if;
 if (select count(*) from public.participants where activity_id=p_activity_id and status<>'cancelled')>=a.capacity then raise exception 'This activity is full'; end if;

 select purchased_credits into balance from public.profiles where id=uid for update;
 if balance is null or balance<a.entry_fee_credits then raise exception 'Insufficient purchased credits. Joining costs % credit(s).',a.entry_fee_credits; end if;
 update public.profiles set purchased_credits=purchased_credits-a.entry_fee_credits,updated_at=now() where id=uid;
 insert into public.participants(activity_id,user_id,status) values(p_activity_id,uid,'joined') returning id into pid;
 insert into public.creation_token_transactions(user_id,amount,reason,activity_id) values(uid,-a.entry_fee_credits,'credit_spent_activity_entry',p_activity_id);
 return pid;
end $$;

create or replace function public.check_in_activity(p_participant_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); p public.participants; a public.activities;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into p from public.participants where id=p_participant_id for update;
 if not found then raise exception 'Participant record not found'; end if;
 select * into a from public.activities where id=p.activity_id;
 if a.creator_id<>uid and p.user_id<>uid then raise exception 'Not authorized'; end if;
 if p.status not in('joined','checked_in') then raise exception 'This participant cannot check in'; end if;
 if now()<a.scheduled_start-interval '15 minutes' then raise exception 'Check-in opens 15 minutes before the activity'; end if;
 if now()>a.scheduled_start+a.duration_minutes*interval '1 minute' then raise exception 'The activity has ended'; end if;
 update public.participants set status='checked_in',checked_in_at=coalesce(checked_in_at,now()) where id=p.id;
 update public.activities set status=case when status='upcoming' then 'check_in'::public.activity_status else status end where id=a.id;
 return true;
end $$;

create or replace function public.confirm_participation(p_participant_id uuid,p_participated boolean)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); p public.participants; a public.activities;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into p from public.participants where id=p_participant_id for update;
 if not found then raise exception 'Participant record not found'; end if;
 select * into a from public.activities where id=p.activity_id;
 if a.creator_id<>uid then raise exception 'Only the activity creator can verify participation'; end if;
 if p.status in('confirmed','completed','cancelled') then raise exception 'Participation has already been finalized'; end if;
 if p_participated then
   update public.participants set status='confirmed',participation_ended_at=now(),reward_eligible_at=greatest(now(),a.scheduled_start+a.duration_minutes*interval '1 minute') where id=p.id;
 else
   update public.participants set status='cancelled',participation_ended_at=now() where id=p.id;
 end if;
 return true;
end $$;

create or replace function public.claim_participation_reward(p_participant_id uuid)
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); p public.participants; a public.activities; reward integer:=5;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into p from public.participants where id=p_participant_id and user_id=uid for update;
 if not found then raise exception 'Your participation record was not found'; end if;
 if p.status<>'confirmed' then raise exception 'Your participation has not been verified by the host'; end if;
 select * into a from public.activities where id=p.activity_id;
 if now()<a.scheduled_start+a.duration_minutes*interval '1 minute' then raise exception 'The activity must finish before you claim the reward'; end if;
 if p.reward_credited_at is not null then raise exception 'This participation reward has already been claimed'; end if;
 update public.profiles set reward_credits=reward_credits+reward,updated_at=now() where id=uid;
 if not found then raise exception 'Player profile not found'; end if;
 update public.participants set status='completed',reward_credited_at=now() where id=p.id;
 insert into public.reward_credit_transactions(user_id,amount,reason,activity_id,participant_id)
 values(uid,reward,'verified_activity_reward',a.id,p.id);
 return reward;
end $$;

create or replace function public.cancel_activity(p_activity_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); a public.activities;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into a from public.activities where id=p_activity_id for update;
 if not found or a.creator_id<>uid then raise exception 'Activity not found or not owned by you'; end if;
 if a.status in('live','completed','cancelled') then raise exception 'This activity can no longer be cancelled'; end if;
 update public.activities set status='cancelled',updated_at=now() where id=a.id;
 update public.participants set status='cancelled',participation_ended_at=now() where activity_id=a.id and status in('joined','checked_in');
 return true;
end $$;

create or replace function public.accept_1v1_challenge(p_challenge_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); c public.challenges_1v1; a public.activities;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into c from public.challenges_1v1 where id=p_challenge_id for update;
 if not found or c.opponent_id<>uid then raise exception 'Challenge not found'; end if;
 if c.status<>'pending' then raise exception 'Challenge is no longer pending'; end if;
 select * into a from public.activities where id=c.activity_id for update;
 if a.status<>'upcoming' or a.scheduled_start<=now() then raise exception 'Challenge can no longer be accepted'; end if;
 update public.challenges_1v1 set status='accepted',accepted_at=now() where id=c.id;
 return true;
end $$;

create or replace function public.edit_activity(
 p_activity_id uuid,p_title text,p_room_code text,p_room_password text,
 p_scheduled_start timestamptz,p_duration_minutes integer,p_capacity integer,
 p_game_mode text,p_map_name text,p_rules text
) returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); a public.activities; is_admin boolean;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select exists(select 1 from public.admin_roles where user_id=uid and role in('admin','super_admin','owner')) into is_admin;
 select * into a from public.activities where id=p_activity_id for update;
 if not found or (a.creator_id<>uid and not is_admin) then raise exception 'Activity not found or not authorized'; end if;
 if a.status<>'upcoming' then raise exception 'Only upcoming activities can be edited'; end if;
 if exists(select 1 from public.participants where activity_id=a.id) then raise exception 'Activities cannot be edited after players join'; end if;
 if coalesce(length(trim(p_title)),0)<3 or p_duration_minutes not between 1 and 720 or p_capacity not between 2 and 100 or p_scheduled_start<=now() then raise exception 'Invalid activity details'; end if;
 if a.type='tournament' and p_capacity not in(4,8,16,32) then raise exception 'Tournament capacity must be 4, 8, 16 or 32 players'; end if;
 update public.activities set title=trim(p_title),scheduled_start=p_scheduled_start,duration_minutes=p_duration_minutes,capacity=p_capacity,game_mode=left(p_game_mode,80),map_name=left(p_map_name,80),rules=left(p_rules,2000),updated_at=now() where id=a.id;
 update public.activity_secrets set room_code=trim(p_room_code),room_password=nullif(trim(p_room_password),''),updated_at=now() where activity_id=a.id;
 return true;
end $$;

-- Public API grants: all balance-changing operations execute only through validated RPCs.
revoke all on function public.create_activity(public.activity_type,text,text,text,timestamptz,integer,integer,text,text,text) from public,anon;
revoke all on function public.create_1v1_challenge(uuid,text,text,text,timestamptz,integer,text,text,text) from public,anon;
revoke all on function public.set_activity_entry_fee(uuid,integer) from public,anon;
revoke all on function public.join_activity(uuid) from public,anon;
revoke all on function public.check_in_activity(uuid) from public,anon;
revoke all on function public.confirm_participation(uuid,boolean) from public,anon;
revoke all on function public.claim_participation_reward(uuid) from public,anon;
revoke all on function public.cancel_activity(uuid) from public,anon;
revoke all on function public.accept_1v1_challenge(uuid) from public,anon;
revoke all on function public.edit_activity(uuid,text,text,text,timestamptz,integer,integer,text,text,text) from public,anon;
grant execute on function public.create_activity(public.activity_type,text,text,text,timestamptz,integer,integer,text,text,text) to authenticated;
grant execute on function public.create_1v1_challenge(uuid,text,text,text,timestamptz,integer,text,text,text) to authenticated;
grant execute on function public.set_activity_entry_fee(uuid,integer) to authenticated;
grant execute on function public.join_activity(uuid) to authenticated;
grant execute on function public.check_in_activity(uuid) to authenticated;
grant execute on function public.confirm_participation(uuid,boolean) to authenticated;
grant execute on function public.claim_participation_reward(uuid) to authenticated;
grant execute on function public.cancel_activity(uuid) to authenticated;
grant execute on function public.accept_1v1_challenge(uuid) to authenticated;
grant execute on function public.edit_activity(uuid,text,text,text,timestamptz,integer,integer,text,text,text) to authenticated;

alter table public.reward_credit_transactions enable row level security;
alter table public.admin_roles enable row level security;
alter table public.reports enable row level security;
drop policy if exists reward_transactions_read_own on public.reward_credit_transactions;
create policy reward_transactions_read_own on public.reward_credit_transactions for select to authenticated using(user_id=auth.uid());
drop policy if exists admin_roles_read_own on public.admin_roles;
create policy admin_roles_read_own on public.admin_roles for select to authenticated using(user_id=auth.uid());
drop policy if exists reports_insert_own on public.reports;
create policy reports_insert_own on public.reports for insert to authenticated with check(reporter_id=auth.uid());
drop policy if exists reports_read_own on public.reports;
create policy reports_read_own on public.reports for select to authenticated using(reporter_id=auth.uid());

grant select on public.reward_credit_transactions,public.admin_roles,public.reports to authenticated;
grant insert on public.reports to authenticated;
revoke update,delete,insert on public.reward_credit_transactions from anon,authenticated;
revoke insert,update,delete on public.admin_roles from anon,authenticated;

commit;

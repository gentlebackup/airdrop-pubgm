-- AIRDROP PUBGM — consolidated fresh-project setup
-- Apply this file ONCE in the SQL Editor of the NEW project:
-- https://supabase.com/dashboard/project/hefzuyonyrbxanwfxibg/sql/new
-- Do not run the legacy incremental migrations separately.
-- This script creates the core app schema, community/feed, tournaments and core activity RPCs.
-- It does not enable cash withdrawals or credit purchases; those remain disabled pending audited payment setup.



-- ===== BEGIN supabase/migrations/20261108090000_airdrop_pubgm_core_foundation.sql =====
-- AIRDROP PUBGM — fresh-project core foundation
-- Phase 1 of the database rebuild. Apply ONLY to the new AIRDROP PUBGM Supabase project.
-- This migration creates core identity/activity tables and secure room-secret access.
-- It intentionally does NOT enable wallet payouts, purchases, or withdrawals.
-- Those workflows require separate audited RPCs and must remain unavailable until then.

begin;

create extension if not exists pgcrypto;

do $$ begin
  create type public.activity_type as enum ('room','tournament','challenge_1v1');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.activity_status as enum ('upcoming','check_in','live','completed','cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.participation_status as enum ('joined','checked_in','confirmed','completed','cancelled');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  profile_name text not null default '',
  username text not null unique,
  region text not null default '',
  phone text,
  game_name text not null default '',
  pubgm_game_id text,
  avatar_url text,
  creation_tokens integer not null default 0 check (creation_tokens >= 0),
  reward_credits integer not null default 0 check (reward_credits >= 0),
  purchased_credits integer not null default 0 check (purchased_credits >= 0),
  game_id_locked boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.public_profiles (
  id uuid primary key references public.profiles(id) on delete cascade,
  profile_name text,
  username text,
  region text,
  game_name text,
  avatar_url text
);

create table if not exists public.creation_token_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null,
  reason text not null,
  activity_id uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.activities (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references auth.users(id) on delete cascade,
  type public.activity_type not null,
  title text not null check (char_length(trim(title)) between 3 and 120),
  scheduled_start timestamptz not null,
  duration_minutes integer not null check (duration_minutes between 1 and 720),
  capacity integer not null check (capacity between 2 and 100),
  game_mode text,
  map_name text,
  rules text,
  status public.activity_status not null default 'upcoming',
  entry_fee_credits integer not null default 0 check (entry_fee_credits >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists activities_schedule_idx on public.activities(scheduled_start);
create index if not exists activities_creator_idx on public.activities(creator_id, created_at desc);

create table if not exists public.activity_secrets (
  activity_id uuid primary key references public.activities(id) on delete cascade,
  room_code text not null,
  room_password text,
  updated_at timestamptz not null default now()
);

create table if not exists public.participants (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null references public.activities(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status public.participation_status not null default 'joined',
  joined_at timestamptz not null default now(),
  checked_in_at timestamptz,
  participation_started_at timestamptz,
  participation_ended_at timestamptz,
  reward_eligible_at timestamptz,
  reward_credited_at timestamptz,
  created_at timestamptz not null default now(),
  unique(activity_id,user_id)
);
create index if not exists participants_user_idx on public.participants(user_id, created_at desc);

create table if not exists public.challenges_1v1 (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null unique references public.activities(id) on delete cascade,
  challenger_id uuid not null references auth.users(id) on delete cascade,
  opponent_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','accepted','declined','completed','cancelled')),
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  check(challenger_id <> opponent_id)
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  body text not null,
  type text not null,
  activity_id uuid references public.activities(id) on delete set null,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  actor_id uuid references auth.users(id) on delete set null,
  message_id uuid,
  action_url text
);
create index if not exists notifications_user_created_idx on public.notifications(user_id,created_at desc);

-- A public profile projection is maintained from the private profile.
create or replace function public.sync_public_profile()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.public_profiles(id,profile_name,username,region,game_name,avatar_url)
  values(new.id,new.profile_name,new.username,new.region,new.game_name,new.avatar_url)
  on conflict(id) do update set
    profile_name=excluded.profile_name,
    username=excluded.username,
    region=excluded.region,
    game_name=excluded.game_name,
    avatar_url=excluded.avatar_url;
  return new;
end $$;

drop trigger if exists profiles_sync_public on public.profiles;
create trigger profiles_sync_public after insert or update of profile_name,username,region,game_name,avatar_url
on public.profiles for each row execute function public.sync_public_profile();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare base_username text;
begin
  base_username := lower(regexp_replace(coalesce(new.email,'player'),'[^a-zA-Z0-9]+','','g'));
  if base_username = '' then base_username := 'player'; end if;
  insert into public.profiles(id,profile_name,username,pubgm_game_id)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),
    base_username || '_' || substr(replace(new.id::text,'-',''),1,6),null)
  on conflict(id) do nothing;
  insert into public.creation_token_transactions(user_id,amount,reason)
  values(new.id,10,'new_user_grant')
  on conflict do nothing;
  update public.profiles set creation_tokens=creation_tokens+10 where id=new.id;
  return new;
end $$;

drop trigger if exists on_auth_user_created_airdrop on auth.users;
create trigger on_auth_user_created_airdrop
after insert on auth.users for each row execute function public.handle_new_user();

-- Activity creation matches the source app's original RPC contract.
create or replace function public.create_activity(
  p_type public.activity_type,
  p_title text,
  p_room_code text,
  p_room_password text,
  p_scheduled_start timestamptz,
  p_duration_minutes integer,
  p_capacity integer,
  p_game_mode text default null,
  p_map_name text default null,
  p_rules text default null
)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid := auth.uid(); aid uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if coalesce(length(trim(p_title)),0)<3 then raise exception 'Activity title is required'; end if;
  if p_duration_minutes is null or p_duration_minutes<1 or p_duration_minutes>720 then raise exception 'Activity duration is invalid'; end if;
  if p_capacity is null or p_capacity<2 or p_capacity>100 then raise exception 'Activity capacity is invalid'; end if;
  if p_scheduled_start is null or p_scheduled_start<=now() then raise exception 'Start time must be in the future'; end if;
  if coalesce(length(trim(p_room_code)),0)=0 then raise exception 'Room code is required'; end if;
  insert into public.activities(creator_id,type,title,scheduled_start,duration_minutes,capacity,game_mode,map_name,rules,entry_fee_credits)
  values(uid,p_type,trim(p_title),p_scheduled_start,p_duration_minutes,p_capacity,left(p_game_mode,80),left(p_map_name,80),left(p_rules,2000),0)
  returning id into aid;
  insert into public.activity_secrets(activity_id,room_code,room_password)
  values(aid,trim(p_room_code),nullif(trim(p_room_password),''));
  return aid;
end $$;

create or replace function public.get_activity_secret(p_activity_id uuid)
returns table(room_code text,room_password text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if not exists (
    select 1 from public.activities a
    where a.id=p_activity_id and
      (a.creator_id=uid or exists(select 1 from public.participants p where p.activity_id=a.id and p.user_id=uid))
  ) then raise exception 'Not authorized to view room details'; end if;
  return query select s.room_code,s.room_password from public.activity_secrets s where s.activity_id=p_activity_id;
end $$;

-- RLS: private profile and secrets are never anonymously readable.
alter table public.profiles enable row level security;
alter table public.public_profiles enable row level security;
alter table public.creation_token_transactions enable row level security;
alter table public.activities enable row level security;
alter table public.activity_secrets enable row level security;
alter table public.participants enable row level security;
alter table public.challenges_1v1 enable row level security;
alter table public.notifications enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using(id=auth.uid());
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
drop policy if exists public_profiles_authenticated_read on public.public_profiles;
create policy public_profiles_authenticated_read on public.public_profiles for select to authenticated using(true);
drop policy if exists creation_tokens_read_own on public.creation_token_transactions;
create policy creation_tokens_read_own on public.creation_token_transactions for select to authenticated using(user_id=auth.uid());
drop policy if exists activities_read_authenticated on public.activities;
create policy activities_read_authenticated on public.activities for select to authenticated using(true);
drop policy if exists activity_secrets_no_direct_access on public.activity_secrets;
create policy activity_secrets_no_direct_access on public.activity_secrets for select to authenticated using(false);
drop policy if exists participants_read_own_or_activity_creator on public.participants;
create policy participants_read_own_or_activity_creator on public.participants for select to authenticated using(user_id=auth.uid() or exists(select 1 from public.activities a where a.id=activity_id and a.creator_id=auth.uid()));
drop policy if exists challenges_read_involved on public.challenges_1v1;
create policy challenges_read_involved on public.challenges_1v1 for select to authenticated using(challenger_id=auth.uid() or opponent_id=auth.uid());
drop policy if exists notifications_read_own on public.notifications;
create policy notifications_read_own on public.notifications for select to authenticated using(user_id=auth.uid());
drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

-- Do not allow clients to alter protected balances or system fields.
revoke update on public.profiles from anon,authenticated;
grant update(profile_name,username,region,phone,game_name,pubgm_game_id,avatar_url)
on public.profiles to authenticated;

revoke all on public.activity_secrets from anon,authenticated;
revoke all on function public.get_activity_secret(uuid) from public;
revoke all on function public.create_activity(public.activity_type,text,text,text,timestamptz,integer,integer,text,text,text) from public;
grant execute on function public.get_activity_secret(uuid) to authenticated;
grant execute on function public.create_activity(public.activity_type,text,text,text,timestamptz,integer,integer,text,text,text) to authenticated;

commit;

-- ===== END supabase/migrations/20261108090000_airdrop_pubgm_core_foundation.sql =====


-- ===== BEGIN supabase/migrations/20261108100000_airdrop_pubgm_activity_operations.sql =====
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

-- ===== END supabase/migrations/20261108100000_airdrop_pubgm_activity_operations.sql =====


-- ===== BEGIN supabase/migrations/20261108110000_airdrop_pubgm_tournament_system.sql =====
-- AIRDROP PUBGM — tournament brackets and evidence-based result submissions
-- Phase 3. Requires core foundation and activity operations migrations.

begin;

create table if not exists public.tournament_stages (
 id uuid primary key default gen_random_uuid(),
 activity_id uuid not null references public.activities(id) on delete cascade,
 stage_number integer not null check(stage_number>0),
 name text not null,
 created_at timestamptz not null default now(),
 unique(activity_id,stage_number)
);

create table if not exists public.tournament_matches (
 id uuid primary key default gen_random_uuid(),
 stage_id uuid not null references public.tournament_stages(id) on delete cascade,
 player_a uuid references auth.users(id) on delete set null,
 player_b uuid references auth.users(id) on delete set null,
 winner_id uuid references auth.users(id) on delete set null,
 scheduled_at timestamptz,
 status text not null default 'pending' check(status in('pending','completed','cancelled')),
 created_at timestamptz not null default now(),
 round_number integer not null,
 match_number integer not null,
 next_match_id uuid references public.tournament_matches(id) on delete set null,
 winner_slot text check(winner_slot in('a','b') or winner_slot is null),
 unique(stage_id,match_number)
);

create table if not exists public.tournament_result_reports (
 id uuid primary key default gen_random_uuid(),
 match_id uuid not null references public.tournament_matches(id) on delete cascade,
 submitted_by uuid not null references auth.users(id) on delete cascade,
 winner_id uuid not null references auth.users(id) on delete cascade,
 evidence_url text not null,
 notes text,
 status text not null default 'pending' check(status in('pending','approved','rejected')),
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 review_note text,
 created_at timestamptz not null default now()
);
create index if not exists tournament_matches_stage_idx on public.tournament_matches(stage_id,round_number,match_number);
create index if not exists tournament_reports_status_idx on public.tournament_result_reports(status,created_at);

create or replace function public.seed_tournament(p_activity_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare
 uid uuid:=auth.uid(); a public.activities; round_no integer:=0; matches_in_round integer;
 bracket_size integer:=1; player_ids uuid[]; player_count integer; player_index integer:=1;
 stage_id_value uuid; match_id_value uuid; next_id uuid; p_a uuid; p_b uuid; slot text;
 r integer; m integer;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into a from public.activities where id=p_activity_id and type='tournament' for update;
 if not found or a.creator_id<>uid then raise exception 'Tournament not found or not owned by you'; end if;
 if a.status not in('upcoming','check_in') then raise exception 'Tournament can no longer be seeded'; end if;
 if a.capacity not in(4,8,16,32) then raise exception 'Tournament capacity must be 4, 8, 16 or 32'; end if;
 if exists(select 1 from public.tournament_stages where activity_id=a.id) then raise exception 'Tournament bracket already exists'; end if;
 select array_agg(user_id order by joined_at,id),count(*) into player_ids,player_count
 from public.participants where activity_id=a.id and status in('joined','checked_in','confirmed','completed');
 if coalesce(player_count,0)<2 then raise exception 'At least 2 participants are required'; end if;
 if player_count>a.capacity then raise exception 'Participant count exceeds tournament capacity'; end if;
 while bracket_size<a.capacity loop bracket_size:=bracket_size*2; end loop;
 matches_in_round:=bracket_size/2;
 while matches_in_round>=1 loop round_no:=round_no+1; matches_in_round:=matches_in_round/2; end loop;

 for r in 1..round_no loop
   matches_in_round:=bracket_size/(2^r);
   insert into public.tournament_stages(activity_id,stage_number,name)
   values(a.id,r,case when matches_in_round=1 then 'Final' when matches_in_round=2 then 'Semifinal' when matches_in_round=4 then 'Quarterfinal' else 'Round of '||(matches_in_round*2) end)
   returning id into stage_id_value;
   for m in 1..matches_in_round loop
     p_a:=null;p_b:=null;
     if r=1 then
       if player_index<=player_count then p_a:=player_ids[player_index];player_index:=player_index+1;end if;
       if player_index<=player_count then p_b:=player_ids[player_index];player_index:=player_index+1;end if;
     end if;
     insert into public.tournament_matches(stage_id,player_a,player_b,round_number,match_number)
     values(stage_id_value,p_a,p_b,r,m);
   end loop;
 end loop;

 -- Wire each match to its next-round slot.
 for r in 1..round_no-1 loop
   for m in 1..(bracket_size/(2^r)) loop
     select tm.id into match_id_value from public.tournament_matches tm
       join public.tournament_stages ts on ts.id=tm.stage_id
       where ts.activity_id=a.id and tm.round_number=r and tm.match_number=m;
     select tm.id into next_id from public.tournament_matches tm
       join public.tournament_stages ts on ts.id=tm.stage_id
       where ts.activity_id=a.id and tm.round_number=r+1 and tm.match_number=((m+1)/2);
     slot:=case when mod(m,2)=1 then 'a' else 'b' end;
     update public.tournament_matches set next_match_id=next_id,winner_slot=slot where id=match_id_value;
   end loop;
 end loop;
 return true;
end $$;

create or replace function public.report_tournament_result(
 p_match_id uuid,p_winner_id uuid,p_evidence_url text,p_notes text default null
) returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); m public.tournament_matches; s public.tournament_stages; a public.activities;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if nullif(trim(p_evidence_url),'') is null then raise exception 'Match evidence is required'; end if;
 select * into m from public.tournament_matches where id=p_match_id for update;
 if not found or m.status<>'pending' then raise exception 'Match is not awaiting a result'; end if;
 if p_winner_id not in(m.player_a,m.player_b) then raise exception 'Winner must be one of the players in this match'; end if;
 if uid not in(m.player_a,m.player_b) then raise exception 'Only a player in this match can submit its result'; end if;
 select * into s from public.tournament_stages where id=m.stage_id;
 select * into a from public.activities where id=s.activity_id;
 if a.status='cancelled' then raise exception 'Tournament is cancelled'; end if;
 if exists(select 1 from public.tournament_result_reports where match_id=m.id and status='pending') then raise exception 'A result is already awaiting admin review'; end if;
 insert into public.tournament_result_reports(match_id,submitted_by,winner_id,evidence_url,notes)
 values(m.id,uid,p_winner_id,left(trim(p_evidence_url),1000),left(p_notes,1000));
 return true;
end $$;

alter table public.tournament_stages enable row level security;
alter table public.tournament_matches enable row level security;
alter table public.tournament_result_reports enable row level security;

drop policy if exists tournament_stages_read_authenticated on public.tournament_stages;
create policy tournament_stages_read_authenticated on public.tournament_stages for select to authenticated using(exists(select 1 from public.activities a where a.id=activity_id));
drop policy if exists tournament_matches_read_authenticated on public.tournament_matches;
create policy tournament_matches_read_authenticated on public.tournament_matches for select to authenticated using(exists(select 1 from public.tournament_stages s join public.activities a on a.id=s.activity_id where s.id=stage_id));
drop policy if exists tournament_reports_read_submitter_or_admin on public.tournament_result_reports;
create policy tournament_reports_read_submitter_or_admin on public.tournament_result_reports for select to authenticated using(submitted_by=auth.uid() or exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));

grant select on public.tournament_stages,public.tournament_matches,public.tournament_result_reports to authenticated;
revoke all on function public.seed_tournament(uuid) from public,anon;
revoke all on function public.report_tournament_result(uuid,uuid,text,text) from public,anon;
grant execute on function public.seed_tournament(uuid) to authenticated;
grant execute on function public.report_tournament_result(uuid,uuid,text,text) to authenticated;

-- Evidence uploads are private: clients may upload only inside their own user folder.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('tournament-evidence','tournament-evidence',false,104857600,
 array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists tournament_evidence_owner_upload on storage.objects;
create policy tournament_evidence_owner_upload on storage.objects for insert to authenticated
with check(bucket_id='tournament-evidence' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists tournament_evidence_owner_read on storage.objects;
create policy tournament_evidence_owner_read on storage.objects for select to authenticated
using(bucket_id='tournament-evidence' and (storage.foldername(name))[1]=auth.uid()::text);

commit;

-- ===== END supabase/migrations/20261108110000_airdrop_pubgm_tournament_system.sql =====


-- ===== BEGIN supabase/migrations/20261031120000_create_social_feed_posts_media_and_interactions.sql =====
-- AIRDROP PUBGM social feed: posts, media, comments, likes and reposts.
-- Development branch only; no production migration has been applied.
-- Posts and interactions are retained independently from existing player/account data.

create table if not exists public.feed_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 140),
  description text not null default '' check (char_length(description) <= 5000),
  hashtags text[] not null default '{}',
  media_path text,
  media_type text check (media_type in ('image','video') or media_type is null),
  media_mime_type text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  is_hidden boolean not null default false
);
create index if not exists feed_posts_created_idx on public.feed_posts(created_at desc) where is_hidden=false;
create index if not exists feed_posts_user_created_idx on public.feed_posts(user_id,created_at desc) where is_hidden=false;

create table if not exists public.feed_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.feed_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  is_hidden boolean not null default false
);
create index if not exists feed_comments_post_idx on public.feed_comments(post_id,created_at asc) where is_hidden=false;

create table if not exists public.feed_reactions (
  post_id uuid not null references public.feed_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  reaction text not null default 'like' check (reaction in ('like')),
  created_at timestamptz not null default now(),
  primary key(post_id,user_id)
);

create table if not exists public.feed_reposts (
  post_id uuid not null references public.feed_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(post_id,user_id)
);

alter table public.feed_posts enable row level security;
alter table public.feed_comments enable row level security;
alter table public.feed_reactions enable row level security;
alter table public.feed_reposts enable row level security;

drop policy if exists "feed posts public read" on public.feed_posts;
create policy "feed posts public read" on public.feed_posts for select to authenticated using (is_hidden=false);
drop policy if exists "feed posts owner insert" on public.feed_posts;
create policy "feed posts owner insert" on public.feed_posts for insert to authenticated with check (auth.uid()=user_id);
drop policy if exists "feed posts owner update" on public.feed_posts;
create policy "feed posts owner update" on public.feed_posts for update to authenticated using (auth.uid()=user_id) with check (auth.uid()=user_id);
drop policy if exists "feed posts owner delete" on public.feed_posts;
create policy "feed posts owner delete" on public.feed_posts for delete to authenticated using (auth.uid()=user_id);

drop policy if exists "feed comments read" on public.feed_comments;
create policy "feed comments read" on public.feed_comments for select to authenticated using (is_hidden=false);
drop policy if exists "feed comments own insert" on public.feed_comments;
create policy "feed comments own insert" on public.feed_comments for insert to authenticated with check (auth.uid()=user_id and exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed comments owner delete" on public.feed_comments;
create policy "feed comments owner delete" on public.feed_comments for delete to authenticated using (auth.uid()=user_id);

drop policy if exists "feed reactions read" on public.feed_reactions;
create policy "feed reactions read" on public.feed_reactions for select to authenticated using (exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed reactions own insert" on public.feed_reactions;
create policy "feed reactions own insert" on public.feed_reactions for insert to authenticated with check (auth.uid()=user_id and exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed reactions own delete" on public.feed_reactions;
create policy "feed reactions own delete" on public.feed_reactions for delete to authenticated using (auth.uid()=user_id);

drop policy if exists "feed reposts read" on public.feed_reposts;
create policy "feed reposts read" on public.feed_reposts for select to authenticated using (exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed reposts own insert" on public.feed_reposts;
create policy "feed reposts own insert" on public.feed_reposts for insert to authenticated with check (auth.uid()=user_id and exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed reposts own delete" on public.feed_reposts;
create policy "feed reposts own delete" on public.feed_reposts for delete to authenticated using (auth.uid()=user_id);

grant select,insert,update,delete on public.feed_posts to authenticated;
grant select,insert,delete on public.feed_comments to authenticated;
grant select,insert,delete on public.feed_reactions to authenticated;
grant select,insert,delete on public.feed_reposts to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('feed-media','feed-media',true,104857600,array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime'])
on conflict(id) do update set public=true,file_size_limit=104857600,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "feed media public read" on storage.objects;
create policy "feed media public read" on storage.objects for select to public using (bucket_id='feed-media');
drop policy if exists "feed media owner upload" on storage.objects;
create policy "feed media owner upload" on storage.objects for insert to authenticated with check (bucket_id='feed-media' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "feed media owner update" on storage.objects;
create policy "feed media owner update" on storage.objects for update to authenticated using (bucket_id='feed-media' and (storage.foldername(name))[1]=auth.uid()::text) with check (bucket_id='feed-media' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "feed media owner delete" on storage.objects;
create policy "feed media owner delete" on storage.objects for delete to authenticated using (bucket_id='feed-media' and (storage.foldername(name))[1]=auth.uid()::text);

-- ===== END supabase/migrations/20261031120000_create_social_feed_posts_media_and_interactions.sql =====


-- ===== BEGIN supabase/migrations/20261108120000_airdrop_pubgm_community_system.sql =====
-- AIRDROP PUBGM — community, follows, messaging and moderation tables
-- Phase 4. Complements the existing feed-media migration.

begin;

alter table public.feed_posts add column if not exists view_count bigint not null default 0;
alter table public.feed_comments add column if not exists parent_comment_id uuid references public.feed_comments(id) on delete cascade;

create table if not exists public.feed_post_views (
 post_id uuid not null references public.feed_posts(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 viewed_at timestamptz not null default now(),
 primary key(post_id,user_id)
);

create table if not exists public.player_follows (
 follower_id uuid not null references auth.users(id) on delete cascade,
 following_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(follower_id,following_id),
 check(follower_id<>following_id)
);

create table if not exists public.player_message_blocks (
 blocker_id uuid not null references auth.users(id) on delete cascade,
 blocked_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(blocker_id,blocked_id),
 check(blocker_id<>blocked_id)
);

create table if not exists public.player_messages (
 id uuid primary key default gen_random_uuid(),
 sender_id uuid not null references auth.users(id) on delete cascade,
 recipient_id uuid not null references auth.users(id) on delete cascade,
 body text not null check(char_length(trim(body)) between 1 and 4000),
 created_at timestamptz not null default now(),
 read_at timestamptz,
 check(sender_id<>recipient_id)
);
create index if not exists player_messages_thread_idx on public.player_messages(sender_id,recipient_id,created_at desc);
create index if not exists player_messages_recipient_idx on public.player_messages(recipient_id,created_at desc);

create table if not exists public.player_message_reports (
 id uuid primary key default gen_random_uuid(),
 reporter_id uuid not null references auth.users(id) on delete cascade,
 message_id uuid not null references public.player_messages(id) on delete cascade,
 reason text not null,
 details text,
 status text not null default 'open' check(status in('open','reviewing','resolved','dismissed')),
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 created_at timestamptz not null default now()
);

create table if not exists public.player_profile_reports (
 id uuid primary key default gen_random_uuid(),
 reporter_id uuid not null references auth.users(id) on delete cascade,
 reported_user_id uuid not null references auth.users(id) on delete cascade,
 reason text not null,
 details text,
 status text not null default 'open' check(status in('open','reviewing','resolved','dismissed')),
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 check(reporter_id<>reported_user_id)
);

create table if not exists public.player_verifications (
 user_id uuid primary key references auth.users(id) on delete cascade,
 verified_by uuid references auth.users(id) on delete set null,
 verified_at timestamptz not null default now()
);

create table if not exists public.player_account_moderation (
 user_id uuid primary key references auth.users(id) on delete cascade,
 status text not null default 'active' check(status in('active','suspended')),
 reason text,
 suspended_until timestamptz,
 updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default now()
);

create table if not exists public.player_moderation_history (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 admin_id uuid references auth.users(id) on delete set null,
 action text not null,
 reason text,
 created_at timestamptz not null default now()
);

create table if not exists public.player_notification_settings (
 user_id uuid primary key references auth.users(id) on delete cascade,
 push_enabled boolean not null default true,
 messages_enabled boolean not null default true,
 social_enabled boolean not null default true,
 announcements_enabled boolean not null default true,
 sound_enabled boolean not null default true,
 sound_volume integer not null default 65 check(sound_volume between 0 and 100),
 activities_enabled boolean not null default true,
 tournaments_enabled boolean not null default true,
 wallet_enabled boolean not null default true,
 missions_enabled boolean not null default true,
 feed_enabled boolean not null default true,
 live_enabled boolean not null default true,
 security_enabled boolean not null default true,
 updated_at timestamptz not null default now()
);

create table if not exists public.live_streams (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 title text not null,
 youtube_url text,
 youtube_video_id text,
 status text not null default 'live' check(status in('live','ended')),
 created_at timestamptz not null default now(),
 ended_at timestamptz,
 platform text not null default 'youtube',
 stream_url text
);

-- Feed view count is deduplicated per signed-in player.
create or replace function public.record_feed_post_view(p_post_id uuid)
returns bigint language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); total bigint;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 insert into public.feed_post_views(post_id,user_id)
 select p.id,uid from public.feed_posts p where p.id=p_post_id and p.is_hidden=false
 on conflict(post_id,user_id) do nothing;
 if not found then
   if not exists(select 1 from public.feed_posts where id=p_post_id and is_hidden=false) then raise exception 'Post not found'; end if;
 else
   update public.feed_posts set view_count=view_count+1 where id=p_post_id;
 end if;
 select view_count into total from public.feed_posts where id=p_post_id;
 return coalesce(total,0);
end $$;

-- Community activity stream exposes only a safe subset of profile data.
create or replace function public.get_community_feed(p_limit integer default 50)
returns table(event_id text,event_type text,user_id uuid,profile_name text,username text,avatar_url text,event_title text,event_detail text,occurred_at timestamptz)
language sql stable security definer set search_path=public,pg_temp as $$
 select 'post:'||p.id::text,'post'::text,p.user_id,pp.profile_name,pp.username,pp.avatar_url,
        p.title,left(coalesce(p.description,''),220),p.created_at
 from public.feed_posts p join public.public_profiles pp on pp.id=p.user_id
 where p.is_hidden=false
 order by p.created_at desc
 limit greatest(1,least(coalesce(p_limit,50),100));
$$;

alter table public.feed_post_views enable row level security;
alter table public.player_follows enable row level security;
alter table public.player_message_blocks enable row level security;
alter table public.player_messages enable row level security;
alter table public.player_message_reports enable row level security;
alter table public.player_profile_reports enable row level security;
alter table public.player_verifications enable row level security;
alter table public.player_account_moderation enable row level security;
alter table public.player_moderation_history enable row level security;
alter table public.player_notification_settings enable row level security;
alter table public.live_streams enable row level security;

drop policy if exists feed_views_read_own on public.feed_post_views;
create policy feed_views_read_own on public.feed_post_views for select to authenticated using(user_id=auth.uid());
drop policy if exists follows_read_involved on public.player_follows;
create policy follows_read_involved on public.player_follows for select to authenticated using(follower_id=auth.uid() or following_id=auth.uid());
drop policy if exists follows_insert_self on public.player_follows;
create policy follows_insert_self on public.player_follows for insert to authenticated with check(follower_id=auth.uid());
drop policy if exists follows_delete_self on public.player_follows;
create policy follows_delete_self on public.player_follows for delete to authenticated using(follower_id=auth.uid());

drop policy if exists blocks_read_involved on public.player_message_blocks;
create policy blocks_read_involved on public.player_message_blocks for select to authenticated using(blocker_id=auth.uid() or blocked_id=auth.uid());
drop policy if exists blocks_insert_self on public.player_message_blocks;
create policy blocks_insert_self on public.player_message_blocks for insert to authenticated with check(blocker_id=auth.uid());
drop policy if exists blocks_delete_self on public.player_message_blocks;
create policy blocks_delete_self on public.player_message_blocks for delete to authenticated using(blocker_id=auth.uid());

drop policy if exists messages_read_participants on public.player_messages;
create policy messages_read_participants on public.player_messages for select to authenticated using(sender_id=auth.uid() or recipient_id=auth.uid());
drop policy if exists messages_send_self on public.player_messages;
create policy messages_send_self on public.player_messages for insert to authenticated with check(sender_id=auth.uid() and not exists(select 1 from public.player_message_blocks b where b.blocker_id=recipient_id and b.blocked_id=auth.uid()) and not exists(select 1 from public.player_message_blocks b where b.blocker_id=auth.uid() and b.blocked_id=recipient_id));
drop policy if exists messages_recipient_read_update on public.player_messages;
create policy messages_recipient_read_update on public.player_messages for update to authenticated using(recipient_id=auth.uid()) with check(recipient_id=auth.uid());

drop policy if exists message_reports_insert_self on public.player_message_reports;
create policy message_reports_insert_self on public.player_message_reports for insert to authenticated with check(reporter_id=auth.uid());
drop policy if exists message_reports_read_self_or_admin on public.player_message_reports;
create policy message_reports_read_self_or_admin on public.player_message_reports for select to authenticated using(reporter_id=auth.uid() or exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));

drop policy if exists profile_reports_insert_self on public.player_profile_reports;
create policy profile_reports_insert_self on public.player_profile_reports for insert to authenticated with check(reporter_id=auth.uid());
drop policy if exists profile_reports_read_self_or_admin on public.player_profile_reports;
create policy profile_reports_read_self_or_admin on public.player_profile_reports for select to authenticated using(reporter_id=auth.uid() or exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));

drop policy if exists verifications_read_authenticated on public.player_verifications;
create policy verifications_read_authenticated on public.player_verifications for select to authenticated using(true);
drop policy if exists moderation_read_self on public.player_account_moderation;
create policy moderation_read_self on public.player_account_moderation for select to authenticated using(user_id=auth.uid());
drop policy if exists moderation_history_read_self on public.player_moderation_history;
create policy moderation_history_read_self on public.player_moderation_history for select to authenticated using(user_id=auth.uid());
drop policy if exists notification_settings_read_self on public.player_notification_settings;
create policy notification_settings_read_self on public.player_notification_settings for select to authenticated using(user_id=auth.uid());
drop policy if exists notification_settings_insert_self on public.player_notification_settings;
create policy notification_settings_insert_self on public.player_notification_settings for insert to authenticated with check(user_id=auth.uid());
drop policy if exists notification_settings_update_self on public.player_notification_settings;
create policy notification_settings_update_self on public.player_notification_settings for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

drop policy if exists live_streams_read_authenticated on public.live_streams;
create policy live_streams_read_authenticated on public.live_streams for select to authenticated using(true);
drop policy if exists live_streams_owner_insert on public.live_streams;
create policy live_streams_owner_insert on public.live_streams for insert to authenticated with check(user_id=auth.uid());
drop policy if exists live_streams_owner_update on public.live_streams;
create policy live_streams_owner_update on public.live_streams for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists live_streams_owner_delete on public.live_streams;
create policy live_streams_owner_delete on public.live_streams for delete to authenticated using(user_id=auth.uid());

grant select on public.feed_post_views,public.player_follows,public.player_message_blocks,public.player_messages,
 public.player_message_reports,public.player_profile_reports,public.player_verifications,
 public.player_account_moderation,public.player_moderation_history,public.player_notification_settings,public.live_streams
 to authenticated;
grant insert,delete on public.player_follows,public.player_message_blocks to authenticated;
grant select,insert,update on public.player_messages to authenticated;
grant insert on public.player_message_reports,public.player_profile_reports to authenticated;
grant insert,update on public.player_notification_settings to authenticated;
grant select,insert,update,delete on public.live_streams to authenticated;

revoke all on function public.record_feed_post_view(uuid) from public,anon;
revoke all on function public.get_community_feed(integer) from public,anon;
grant execute on function public.record_feed_post_view(uuid) to authenticated;
grant execute on function public.get_community_feed(integer) to authenticated;

commit;

-- ===== END supabase/migrations/20261108120000_airdrop_pubgm_community_system.sql =====

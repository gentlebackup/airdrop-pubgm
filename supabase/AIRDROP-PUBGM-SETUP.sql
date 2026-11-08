-- AIRDROP PUBGM — consolidated fresh-project database setup
-- Generated from the repository's ordered baseline and feature migrations.
-- Intended only for the NEW project: https://hefzuyonyrbxanwfxibg.supabase.co
-- Run ONCE in that project's SQL Editor. Never run against the old CODM project.
-- Credit purchases and withdrawals are disabled by default. This script does not configure payment credentials.
-- A successful SQL run does not replace the app build, auth, storage, and end-to-end checks.



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


-- ===== BEGIN supabase/migrations/20261108130000_airdrop_pubgm_wallet_progression_schema.sql =====
-- AIRDROP PUBGM — wallet, progression, cosmetics and admin queue schema
-- Phase 5. Wallet payouts and purchase approvals are intentionally not activated here.

begin;

alter table public.profiles
 add column if not exists equipped_mission_level integer,
 add column if not exists equipped_name_style text not null default 'default',
 add column if not exists equipped_badge_level integer,
 add column if not exists equipped_collectible_level integer,
 add column if not exists equipped_store_cosmetic_id uuid,
 add column if not exists equipped_name_style_cosmetic_id uuid,
 add column if not exists equipped_profile_frame_id uuid,
 add column if not exists equipped_profile_theme_id uuid,
 add column if not exists equipped_avatar_effect_id uuid;

create table if not exists public.achievements (
 id uuid primary key default gen_random_uuid(),
 code text not null unique,
 name text not null,
 description text not null default '',
 icon text not null default '🏅',
 requirement_type text not null,
 requirement_value integer not null check(requirement_value>=0),
 created_at timestamptz not null default now()
);

create table if not exists public.user_achievements (
 user_id uuid not null references auth.users(id) on delete cascade,
 achievement_id uuid not null references public.achievements(id) on delete cascade,
 unlocked_at timestamptz not null default now(),
 primary key(user_id,achievement_id)
);

create table if not exists public.seasons (
 id uuid primary key default gen_random_uuid(),
 name text not null,
 starts_at timestamptz not null,
 ends_at timestamptz not null,
 status text not null default 'active' check(status in('upcoming','active','completed')),
 created_at timestamptz not null default now(),
 check(ends_at>starts_at)
);

create table if not exists public.player_progression (
 user_id uuid not null references auth.users(id) on delete cascade,
 season_id uuid references public.seasons(id) on delete set null,
 xp integer not null default 0 check(xp>=0),
 level integer not null default 1 check(level>=1),
 updated_at timestamptz not null default now(),
 primary key(user_id,season_id)
);

create table if not exists public.user_activity_stats (
 user_id uuid primary key references auth.users(id) on delete cascade,
 matches_joined integer not null default 0,
 matches_completed integer not null default 0,
 tournaments_joined integer not null default 0,
 tournaments_created integer not null default 0,
 challenges_created integer not null default 0,
 challenges_completed integer not null default 0,
 cancellations integer not null default 0,
 updated_at timestamptz not null default now()
);

create table if not exists public.profile_cosmetics (
 id uuid primary key default gen_random_uuid(),
 code text not null unique,
 name text not null,
 category text not null,
 description text not null default '',
 price_credits integer not null default 0 check(price_credits>=0),
 style_key text not null,
 active boolean not null default true,
 sort_order integer not null default 0,
 created_at timestamptz not null default now()
);

create table if not exists public.profile_cosmetic_inventory (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 cosmetic_id uuid not null references public.profile_cosmetics(id) on delete cascade,
 purchased_at timestamptz not null default now(),
 unique(user_id,cosmetic_id)
);

create table if not exists public.profile_mission_entries (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 activity_id uuid not null references public.activities(id) on delete cascade,
 participant_id uuid references public.participants(id) on delete set null,
 entry_fee_credits integer not null default 1,
 status text not null default 'pending_admin_review',
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 reviewer_note text,
 created_at timestamptz not null default now(),
 unique(user_id,activity_id)
);

create table if not exists public.profile_mission_level_claims (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 level integer not null,
 required_activities integer not null,
 cash_reward_usd numeric(12,2) not null default 0,
 status text not null default 'pending_admin_review',
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 paid_at timestamptz,
 reviewer_note text,
 created_at timestamptz not null default now(),
 collectible_code text,
 claimed_at timestamptz,
 payout_reference text,
 unique(user_id,level)
);

create table if not exists public.credit_purchase_settings (
 id boolean primary key default true check(id),
 enabled boolean not null default false,
 receiving_bank_name text,
 receiving_account_name text,
 receiving_account_number text,
 updated_at timestamptz not null default now()
);
insert into public.credit_purchase_settings(id,enabled) values(true,false) on conflict(id) do nothing;

create table if not exists public.credit_purchase_requests (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 package_credits integer not null check(package_credits>0),
 amount_ngn integer not null check(amount_ngn>0),
 transfer_reference text,
 status text not null default 'pending' check(status in('pending','under_review','approved','rejected')),
 reviewer_note text,
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 created_at timestamptz not null default now()
);

create table if not exists public.withdrawal_settings (
 id boolean primary key default true check(id),
 enabled boolean not null default false,
 updated_at timestamptz not null default now()
);
insert into public.withdrawal_settings(id,enabled) values(true,false) on conflict(id) do nothing;

create table if not exists public.withdrawal_requests (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 requested_credits integer not null check(requested_credits>0),
 exchange_rate numeric(12,4) not null default 10,
 fee_credits integer not null default 0,
 payout_amount numeric(14,2) not null,
 currency text not null default 'NGN',
 bank_name text not null,
 account_number text not null,
 status text not null default 'pending' check(status in('pending','under_review','approved','rejected','paid','cancelled')),
 reviewer_note text,
 created_at timestamptz not null default now(),
 reviewed_at timestamptz,
 paid_at timestamptz,
 credits_reserved boolean not null default false,
 account_name text,
 recipient_country_code text,
 payment_method text,
 recipient_details jsonb not null default '{}'::jsonb
);

create table if not exists public.audit_logs (
 id uuid primary key default gen_random_uuid(),
 actor_user_id uuid references auth.users(id) on delete set null,
 action text not null,
 entity_type text not null,
 entity_id uuid,
 metadata jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

create table if not exists public.site_media_settings (
 id boolean primary key default true check(id),
 trailer_video_url text,
 trailer_thumbnail_url text,
 trailer_title text not null default 'Latest PUBG Mobile season trailer',
 updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default now()
);
insert into public.site_media_settings(id) values(true) on conflict(id) do nothing;

create table if not exists public.push_subscriptions (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 endpoint text not null,
 p256dh text not null,
 auth text not null,
 user_agent text,
 is_active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(user_id,endpoint)
);

alter table public.achievements enable row level security;
alter table public.user_achievements enable row level security;
alter table public.seasons enable row level security;
alter table public.player_progression enable row level security;
alter table public.user_activity_stats enable row level security;
alter table public.profile_cosmetics enable row level security;
alter table public.profile_cosmetic_inventory enable row level security;
alter table public.profile_mission_entries enable row level security;
alter table public.profile_mission_level_claims enable row level security;
alter table public.credit_purchase_settings enable row level security;
alter table public.credit_purchase_requests enable row level security;
alter table public.withdrawal_settings enable row level security;
alter table public.withdrawal_requests enable row level security;
alter table public.audit_logs enable row level security;
alter table public.site_media_settings enable row level security;
alter table public.push_subscriptions enable row level security;

drop policy if exists achievements_read_authenticated on public.achievements;
create policy achievements_read_authenticated on public.achievements for select to authenticated using(true);
drop policy if exists user_achievements_read_own on public.user_achievements;
create policy user_achievements_read_own on public.user_achievements for select to authenticated using(user_id=auth.uid());
drop policy if exists seasons_read_authenticated on public.seasons;
create policy seasons_read_authenticated on public.seasons for select to authenticated using(true);
drop policy if exists progression_read_own on public.player_progression;
create policy progression_read_own on public.player_progression for select to authenticated using(user_id=auth.uid());
drop policy if exists stats_read_own on public.user_activity_stats;
create policy stats_read_own on public.user_activity_stats for select to authenticated using(user_id=auth.uid());
drop policy if exists cosmetics_read_authenticated on public.profile_cosmetics;
create policy cosmetics_read_authenticated on public.profile_cosmetics for select to authenticated using(active=true);
drop policy if exists inventory_read_own on public.profile_cosmetic_inventory;
create policy inventory_read_own on public.profile_cosmetic_inventory for select to authenticated using(user_id=auth.uid());
drop policy if exists mission_entries_read_own on public.profile_mission_entries;
create policy mission_entries_read_own on public.profile_mission_entries for select to authenticated using(user_id=auth.uid());
drop policy if exists mission_claims_read_own on public.profile_mission_level_claims;
create policy mission_claims_read_own on public.profile_mission_level_claims for select to authenticated using(user_id=auth.uid());
drop policy if exists purchase_settings_read_authenticated on public.credit_purchase_settings;
create policy purchase_settings_read_authenticated on public.credit_purchase_settings for select to authenticated using(true);
drop policy if exists purchase_requests_read_own on public.credit_purchase_requests;
create policy purchase_requests_read_own on public.credit_purchase_requests for select to authenticated using(user_id=auth.uid());
drop policy if exists withdrawal_settings_read_authenticated on public.withdrawal_settings;
create policy withdrawal_settings_read_authenticated on public.withdrawal_settings for select to authenticated using(true);
drop policy if exists withdrawal_requests_read_own on public.withdrawal_requests;
create policy withdrawal_requests_read_own on public.withdrawal_requests for select to authenticated using(user_id=auth.uid());
drop policy if exists site_media_read_authenticated on public.site_media_settings;
create policy site_media_read_authenticated on public.site_media_settings for select to authenticated using(true);
drop policy if exists push_subscriptions_read_own on public.push_subscriptions;
create policy push_subscriptions_read_own on public.push_subscriptions for select to authenticated using(user_id=auth.uid());
drop policy if exists push_subscriptions_insert_own on public.push_subscriptions;
create policy push_subscriptions_insert_own on public.push_subscriptions for insert to authenticated with check(user_id=auth.uid());
drop policy if exists push_subscriptions_update_own on public.push_subscriptions;
create policy push_subscriptions_update_own on public.push_subscriptions for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists push_subscriptions_delete_own on public.push_subscriptions;
create policy push_subscriptions_delete_own on public.push_subscriptions for delete to authenticated using(user_id=auth.uid());

grant select on public.achievements,public.user_achievements,public.seasons,public.player_progression,
 public.user_activity_stats,public.profile_cosmetics,public.profile_cosmetic_inventory,
 public.profile_mission_entries,public.profile_mission_level_claims,public.credit_purchase_settings,
 public.credit_purchase_requests,public.withdrawal_settings,public.withdrawal_requests,
 public.site_media_settings,public.push_subscriptions to authenticated;
grant insert,update,delete on public.push_subscriptions to authenticated;
revoke insert,update,delete on public.achievements,public.user_achievements,public.seasons,
 public.player_progression,public.user_activity_stats,public.profile_cosmetics,
 public.profile_cosmetic_inventory,public.profile_mission_entries,public.profile_mission_level_claims,
 public.credit_purchase_settings,public.credit_purchase_requests,public.withdrawal_settings,
 public.withdrawal_requests,public.audit_logs,public.site_media_settings from anon,authenticated;

commit;

-- ===== END supabase/migrations/20261108130000_airdrop_pubgm_wallet_progression_schema.sql =====


-- ===== BEGIN supabase/migrations/20261108140000_airdrop_pubgm_progression_store_rpcs.sql =====
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

-- ===== END supabase/migrations/20261108140000_airdrop_pubgm_progression_store_rpcs.sql =====


-- ===== BEGIN supabase/migrations/20261108150000_airdrop_pubgm_admin_rpcs.sql =====
-- AIRDROP PUBGM — restricted admin review and moderation RPCs
-- Phase 7. All admin actions require a row in public.admin_roles.
-- Cash-out remains unavailable; no RPC here initiates or marks a bank transfer paid.

begin;

create or replace function public._airdrop_require_admin(p_moderator boolean default false)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();
begin
 if uid is null or not exists(
  select 1 from public.admin_roles r where r.user_id=uid
   and (r.role in('admin','super_admin','owner') or (p_moderator and r.role='moderator'))
 ) then raise exception 'Admin access required'; end if;
 return uid;
end $$;

create or replace function public.admin_reports()
returns setof public.reports language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public._airdrop_require_admin(true); return query select * from public.reports order by created_at desc; end $$;

create or replace function public.admin_withdrawals()
returns setof public.withdrawal_requests language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public._airdrop_require_admin(false); return query select * from public.withdrawal_requests order by created_at desc; end $$;

create or replace function public.admin_credit_purchase_requests()
returns setof public.credit_purchase_requests language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public._airdrop_require_admin(false); return query select * from public.credit_purchase_requests order by created_at desc; end $$;

create or replace function public.admin_profile_mission_entries()
returns table(id uuid,user_id uuid,activity_id uuid,participant_id uuid,entry_fee_credits integer,status text,reviewed_by uuid,reviewed_at timestamptz,reviewer_note text,created_at timestamptz,profile_name text,username text,pubgm_game_id text,activity_title text)
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform public._airdrop_require_admin(false);
 return query select e.id,e.user_id,e.activity_id,e.participant_id,e.entry_fee_credits,e.status,e.reviewed_by,e.reviewed_at,e.reviewer_note,e.created_at,p.profile_name,p.username,p.pubgm_game_id,a.title
 from public.profile_mission_entries e join public.profiles p on p.id=e.user_id join public.activities a on a.id=e.activity_id
 order by e.created_at asc;
end $$;

create or replace function public.admin_profile_mission_level_claims()
returns setof public.profile_mission_level_claims language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public._airdrop_require_admin(false); return query select * from public.profile_mission_level_claims order by created_at asc; end $$;

create or replace function public.admin_player_profile_reports()
returns setof public.player_profile_reports language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public._airdrop_require_admin(true); return query select * from public.player_profile_reports order by created_at desc; end $$;

create or replace function public.admin_adjust_player_credits(p_user_id uuid,p_amount integer,p_reason text)
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=public._airdrop_require_admin(false); new_balance integer;
begin
 if p_user_id is null or p_amount is null or p_amount=0 or nullif(trim(p_reason),'') is null then raise exception 'A player, non-zero amount and reason are required'; end if;
 update public.profiles set purchased_credits=purchased_credits+p_amount,updated_at=now()
 where id=p_user_id and purchased_credits+p_amount>=0 returning purchased_credits into new_balance;
 if not found then raise exception 'Player not found or adjustment would make the balance negative'; end if;
 insert into public.creation_token_transactions(user_id,amount,reason) values(p_user_id,p_amount,'admin_adjustment: '||left(trim(p_reason),200));
 insert into public.audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
 values(uid,'admin_credit_adjustment','player',p_user_id,jsonb_build_object('amount',p_amount,'reason',left(trim(p_reason),200)));
 return new_balance;
end $$;

create or replace function public.admin_review_credit_purchase(p_request_id uuid,p_decision text,p_note text default null)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=public._airdrop_require_admin(false); r public.credit_purchase_requests;
begin
 select * into r from public.credit_purchase_requests where id=p_request_id for update;
 if not found or r.status not in('pending','under_review') then raise exception 'Open credit purchase request not found'; end if;
 if p_decision not in('under_review','approved','rejected') then raise exception 'Invalid purchase decision'; end if;
 if p_decision='approved' then
  update public.profiles set purchased_credits=purchased_credits+r.package_credits,updated_at=now() where id=r.user_id;
  if not found then raise exception 'Player profile not found'; end if;
  insert into public.creation_token_transactions(user_id,amount,reason)
  values(r.user_id,r.package_credits,'credit_purchase_approved');
 end if;
 update public.credit_purchase_requests set status=p_decision,reviewer_note=nullif(trim(coalesce(p_note,'')),''),reviewed_by=uid,reviewed_at=now() where id=r.id;
 insert into public.audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
 values(uid,'credit_purchase_'||p_decision,'credit_purchase',r.id,jsonb_build_object('user_id',r.user_id,'credits',r.package_credits,'amount_ngn',r.amount_ngn));
end $$;

create or replace function public.admin_review_profile_mission_entry(p_entry_id uuid,p_decision text,p_note text default null)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=public._airdrop_require_admin(false); e public.profile_mission_entries;
begin
 select * into e from public.profile_mission_entries where id=p_entry_id for update;
 if not found or e.status<>'pending_admin_review' then raise exception 'Pending mission entry not found'; end if;
 if p_decision not in('approved','rejected') then raise exception 'Invalid decision'; end if;
 update public.profile_mission_entries set status=p_decision,reviewed_by=uid,reviewed_at=now(),reviewer_note=left(p_note,1000) where id=e.id;
end $$;

create or replace function public.admin_review_profile_mission_level_claim(
 p_claim_id uuid,p_decision text,p_note text default null,p_payout_reference text default null
) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=public._airdrop_require_admin(false); c public.profile_mission_level_claims;
begin
 select * into c from public.profile_mission_level_claims where id=p_claim_id for update;
 if not found then raise exception 'Mission reward claim not found'; end if;
 if p_decision not in('approved_for_payout','rejected','paid') then raise exception 'Invalid claim decision'; end if;
 if p_decision='paid' and nullif(trim(p_payout_reference),'') is null then raise exception 'Record the external payout reference'; end if;
 if p_decision='paid' and c.status<>'approved_for_payout' then raise exception 'Only an approved claim can be marked paid'; end if;
 if p_decision='approved_for_payout' and c.status<>'pending_admin_review' then raise exception 'Only a pending claim can be approved'; end if;
 update public.profile_mission_level_claims set status=p_decision,reviewed_by=uid,reviewed_at=now(),paid_at=case when p_decision='paid' then now() else paid_at end,reviewer_note=left(p_note,1000),payout_reference=case when p_decision='paid' then left(p_payout_reference,200) else payout_reference end where id=c.id;
 insert into public.audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
 values(uid,'mission_reward_claim_'||p_decision,'mission_claim',c.id,jsonb_build_object('user_id',c.user_id,'payout_reference',p_payout_reference));
end $$;

create or replace function public.moderate_report(p_report_id uuid,p_status text,p_note text default null)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=public._airdrop_require_admin(true);
begin
 if p_status not in('reviewing','resolved','dismissed') then raise exception 'Invalid report status'; end if;
 update public.reports set status=p_status where id=p_report_id;
 if not found then raise exception 'Report not found'; end if;
 insert into public.audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
 values(uid,'report_'||p_status,'report',p_report_id,jsonb_build_object('note',left(p_note,1000)));
 return true;
end $$;

create or replace function public.admin_update_player_moderation(
 p_user_id uuid,p_action text,p_reason text,p_suspended_until timestamptz default null
) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=public._airdrop_require_admin(false); new_status text;
begin
 if p_action not in('suspended','reinstated') then raise exception 'Invalid moderation action'; end if;
 if nullif(trim(p_reason),'') is null then raise exception 'A moderation reason is required'; end if;
 if p_action='suspended' and p_suspended_until is not null and p_suspended_until<=now() then raise exception 'Suspension expiry must be in the future'; end if;
 new_status:=case when p_action='suspended' then 'suspended' else 'active' end;
 insert into public.player_account_moderation(user_id,status,reason,suspended_until,updated_by,updated_at)
 values(p_user_id,new_status,left(trim(p_reason),1000),case when new_status='suspended' then p_suspended_until else null end,uid,now())
 on conflict(user_id) do update set status=excluded.status,reason=excluded.reason,suspended_until=excluded.suspended_until,updated_by=uid,updated_at=now();
 insert into public.player_moderation_history(user_id,admin_id,action,reason)
 values(p_user_id,uid,p_action,left(trim(p_reason),1000));
 insert into public.audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
 values(uid,'player_'||p_action,'player',p_user_id,jsonb_build_object('reason',left(trim(p_reason),1000),'suspended_until',p_suspended_until));
end $$;

create or replace function public.admin_review_tournament_result(p_report_id uuid,p_decision text,p_note text default null)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=public._airdrop_require_admin(true); r public.tournament_result_reports; m public.tournament_matches; s public.tournament_stages; a public.activities; n public.tournament_matches;
begin
 if p_decision not in('approved','rejected') then raise exception 'Invalid result decision'; end if;
 select * into r from public.tournament_result_reports where id=p_report_id for update;
 if not found or r.status<>'pending' then raise exception 'Pending result report not found'; end if;
 select * into m from public.tournament_matches where id=r.match_id for update;
 if not found or m.status<>'pending' then raise exception 'Match is no longer pending'; end if;
 if p_decision='approved' then
  if r.winner_id is distinct from m.player_a and r.winner_id is distinct from m.player_b then raise exception 'Reported winner is not in this match'; end if;
  update public.tournament_matches set winner_id=r.winner_id,status='completed' where id=m.id;
  if m.next_match_id is not null then
   select * into n from public.tournament_matches where id=m.next_match_id for update;
   if m.winner_slot='a' then
    if n.player_a is not null and n.player_a<>r.winner_id then raise exception 'Next bracket slot is already occupied'; end if;
    update public.tournament_matches set player_a=r.winner_id where id=n.id and player_a is null;
   elsif m.winner_slot='b' then
    if n.player_b is not null and n.player_b<>r.winner_id then raise exception 'Next bracket slot is already occupied'; end if;
    update public.tournament_matches set player_b=r.winner_id where id=n.id and player_b is null;
   else raise exception 'Bracket advancement slot is missing'; end if;
  else
   select * into s from public.tournament_stages where id=m.stage_id;
   update public.activities set status='completed',updated_at=now() where id=s.activity_id;
  end if;
 end if;
 update public.tournament_result_reports set status=p_decision,reviewed_by=uid,reviewed_at=now(),review_note=left(p_note,1000) where id=r.id;
 insert into public.audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
 values(uid,'tournament_result_'||p_decision,'tournament_result',r.id,jsonb_build_object('winner_id',r.winner_id,'note',left(p_note,1000)));
 return true;
end $$;

-- No withdrawal RPC is exposed in this phase. The setting remains false.
update public.withdrawal_settings set enabled=false where id=true;
update public.credit_purchase_settings set enabled=false where id=true;

revoke all on function public._airdrop_require_admin(boolean) from public,anon,authenticated;
revoke all on function public.admin_reports() from public,anon;
revoke all on function public.admin_withdrawals() from public,anon;
revoke all on function public.admin_credit_purchase_requests() from public,anon;
revoke all on function public.admin_profile_mission_entries() from public,anon;
revoke all on function public.admin_profile_mission_level_claims() from public,anon;
revoke all on function public.admin_player_profile_reports() from public,anon;
revoke all on function public.admin_adjust_player_credits(uuid,integer,text) from public,anon;
revoke all on function public.admin_review_credit_purchase(uuid,text,text) from public,anon;
revoke all on function public.admin_review_profile_mission_entry(uuid,text,text) from public,anon;
revoke all on function public.admin_review_profile_mission_level_claim(uuid,text,text,text) from public,anon;
revoke all on function public.moderate_report(uuid,text,text) from public,anon;
revoke all on function public.admin_update_player_moderation(uuid,text,text,timestamptz) from public,anon;
revoke all on function public.admin_review_tournament_result(uuid,text,text) from public,anon;

grant execute on function public.admin_reports() to authenticated;
grant execute on function public.admin_withdrawals() to authenticated;
grant execute on function public.admin_credit_purchase_requests() to authenticated;
grant execute on function public.admin_profile_mission_entries() to authenticated;
grant execute on function public.admin_profile_mission_level_claims() to authenticated;
grant execute on function public.admin_player_profile_reports() to authenticated;
grant execute on function public.admin_adjust_player_credits(uuid,integer,text) to authenticated;
grant execute on function public.admin_review_credit_purchase(uuid,text,text) to authenticated;
grant execute on function public.admin_review_profile_mission_entry(uuid,text,text) to authenticated;
grant execute on function public.admin_review_profile_mission_level_claim(uuid,text,text,text) to authenticated;
grant execute on function public.moderate_report(uuid,text,text) to authenticated;
grant execute on function public.admin_update_player_moderation(uuid,text,text,timestamptz) to authenticated;
grant execute on function public.admin_review_tournament_result(uuid,text,text) to authenticated;

commit;

-- ===== END supabase/migrations/20261108150000_airdrop_pubgm_admin_rpcs.sql =====


-- ===== BEGIN supabase/migrations/20261108160000_airdrop_pubgm_postgrest_privileges.sql =====
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

-- ===== END supabase/migrations/20261108160000_airdrop_pubgm_postgrest_privileges.sql =====


-- ===== BEGIN supabase/migrations/20261108170000_airdrop_pubgm_disabled_withdrawal_guards.sql =====
-- AIRDROP PUBGM — explicit disabled-state responses for cash withdrawals
-- The wallet UI gets a safe, understandable response while payout controls are off.

begin;

create or replace function public.request_withdrawal(
 p_requested_credits integer,p_bank_name text,p_account_name text,p_account_number text
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare enabled_value boolean;
begin
 select enabled into enabled_value from public.withdrawal_settings where id=true;
 if not coalesce(enabled_value,false) then
  raise exception 'Cash withdrawals are not enabled yet. Your reward credits remain in your wallet.';
 end if;
 raise exception 'Withdrawal processing has not been activated. Your reward credits remain in your wallet.';
end $$;

create or replace function public.admin_update_withdrawal(
 p_withdrawal_id uuid,p_status text,p_note text default null
) returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform public._airdrop_require_admin(false);
 raise exception 'Cash withdrawal processing is disabled. No payout status was changed.';
end $$;

revoke all on function public.request_withdrawal(integer,text,text,text) from public,anon;
revoke all on function public.admin_update_withdrawal(uuid,text,text) from public,anon;
grant execute on function public.request_withdrawal(integer,text,text,text) to authenticated;
grant execute on function public.admin_update_withdrawal(uuid,text,text) to authenticated;

commit;

-- ===== END supabase/migrations/20261108170000_airdrop_pubgm_disabled_withdrawal_guards.sql =====


-- ===== BEGIN supabase/migrations/20261108180000_airdrop_pubgm_admin_dashboard_policies.sql =====
-- AIRDROP PUBGM — admin-only direct-table access required by the admin dashboard

begin;

drop policy if exists profiles_admin_read on public.profiles;
create policy profiles_admin_read on public.profiles for select to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));

drop policy if exists verification_admin_insert on public.player_verifications;
create policy verification_admin_insert on public.player_verifications for insert to authenticated
with check(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')));
drop policy if exists verification_admin_delete on public.player_verifications;
create policy verification_admin_delete on public.player_verifications for delete to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')));

drop policy if exists moderation_admin_read on public.player_account_moderation;
create policy moderation_admin_read on public.player_account_moderation for select to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')));

drop policy if exists message_reports_admin_read on public.player_message_reports;
create policy message_reports_admin_read on public.player_message_reports for select to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));

drop policy if exists site_media_admin_update on public.site_media_settings;
create policy site_media_admin_update on public.site_media_settings for update to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')))
with check(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')));

grant select on public.profiles,public.player_account_moderation,public.player_message_reports to authenticated;
grant insert,delete on public.player_verifications to authenticated;
grant update(trailer_video_url,trailer_thumbnail_url,trailer_title,updated_by,updated_at)
on public.site_media_settings to authenticated;

commit;

-- ===== END supabase/migrations/20261108180000_airdrop_pubgm_admin_dashboard_policies.sql =====


-- ===== BEGIN supabase/migrations/20261108190000_airdrop_pubgm_mission_level_rpcs.sql =====
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

-- ===== END supabase/migrations/20261108190000_airdrop_pubgm_mission_level_rpcs.sql =====


-- ===== BEGIN supabase/migrations/20261108200000_airdrop_pubgm_tournament_bye_fix.sql =====
-- AIRDROP PUBGM — correct partial-capacity tournament bye seeding
-- Uses the next power-of-two bracket for the actual number of entrants.

begin;

create or replace function public.seed_tournament(p_activity_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare
 uid uuid:=auth.uid(); a public.activities; player_ids uuid[]; player_count integer;
 bracket_size integer:=1; bye_count integer; round_count integer:=0;
 stage_id_value uuid; match_id_value uuid; next_id uuid; p_a uuid; p_b uuid; slot text;
 r integer; m integer; player_index integer:=1; matches_in_round integer;
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

 while bracket_size<player_count loop bracket_size:=bracket_size*2; end loop;
 bye_count:=bracket_size-player_count;
 matches_in_round:=bracket_size/2;
 while matches_in_round>=1 loop round_count:=round_count+1; matches_in_round:=matches_in_round/2; end loop;

 for r in 1..round_count loop
  matches_in_round:=bracket_size/(2^r);
  insert into public.tournament_stages(activity_id,stage_number,name)
  values(a.id,r,case when matches_in_round=1 then 'Final' when matches_in_round=2 then 'Semifinal' when matches_in_round=4 then 'Quarterfinal' else 'Round of '||(matches_in_round*2) end)
  returning id into stage_id_value;
  for m in 1..matches_in_round loop
   p_a:=null;p_b:=null;
   if r=1 then
    if m<=bye_count then
     if player_index<=player_count then p_a:=player_ids[player_index];player_index:=player_index+1;end if;
    else
     if player_index<=player_count then p_a:=player_ids[player_index];player_index:=player_index+1;end if;
     if player_index<=player_count then p_b:=player_ids[player_index];player_index:=player_index+1;end if;
    end if;
   end if;
   insert into public.tournament_matches(stage_id,player_a,player_b,round_number,match_number)
   values(stage_id_value,p_a,p_b,r,m) returning id into match_id_value;
  end loop;
 end loop;

 for r in 1..round_count-1 loop
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

 -- Advance automatic byes after the bracket links are in place.
 for r in 1..round_count loop
  for match_id_value in
   select tm.id from public.tournament_matches tm
   join public.tournament_stages ts on ts.id=tm.stage_id
   where ts.activity_id=a.id and tm.round_number=r order by tm.match_number
  loop
   select player_a,player_b,next_match_id,winner_slot into p_a,p_b,next_id,slot
   from public.tournament_matches where id=match_id_value for update;
   if (p_a is null) <> (p_b is null) then
    update public.tournament_matches set winner_id=coalesce(p_a,p_b),status='completed' where id=match_id_value;
    if next_id is not null then
     if slot='a' then update public.tournament_matches set player_a=coalesce(p_a,p_b) where id=next_id and player_a is null;
     else update public.tournament_matches set player_b=coalesce(p_a,p_b) where id=next_id and player_b is null; end if;
    else
     update public.activities set status='completed',updated_at=now() where id=a.id;
    end if;
   end if;
  end loop;
 end loop;
 return true;
end $$;

revoke all on function public.seed_tournament(uuid) from public,anon;
grant execute on function public.seed_tournament(uuid) to authenticated;

commit;

-- ===== END supabase/migrations/20261108200000_airdrop_pubgm_tournament_bye_fix.sql =====


-- ===== BEGIN supabase/migrations/20261108210000_airdrop_pubgm_message_report_policy.sql =====
-- AIRDROP PUBGM — allow players to submit message reports, with admin-only review access

begin;
drop policy if exists message_reports_insert_self on public.player_message_reports;
create policy message_reports_insert_self on public.player_message_reports for insert to authenticated
with check(reporter_id=auth.uid() and exists(select 1 from public.player_messages m where m.id=message_id and (m.sender_id=auth.uid() or m.recipient_id=auth.uid())));
grant insert on public.player_message_reports to authenticated;
revoke update,delete on public.player_message_reports from anon,authenticated;
commit;

-- ===== END supabase/migrations/20261108210000_airdrop_pubgm_message_report_policy.sql =====


-- ===== BEGIN supabase/migrations/20261108220000_airdrop_pubgm_admin_player_directory.sql =====
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

-- ===== END supabase/migrations/20261108220000_airdrop_pubgm_admin_player_directory.sql =====


-- ===== BEGIN supabase/migrations/20261108230000_airdrop_pubgm_game_id_lock.sql =====
-- AIRDROP PUBGM — lock PUBG Mobile account ID after first save
-- Users may set an empty game ID once; they cannot later replace or clear it.

begin;

create or replace function public.prevent_pubgm_game_id_change()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if old.pubgm_game_id is not null
    and nullif(trim(old.pubgm_game_id),'') is not null
    and new.pubgm_game_id is distinct from old.pubgm_game_id then
  raise exception 'Your PUBG Mobile ID is locked and cannot be changed.';
 end if;
 if old.pubgm_game_id is null and nullif(trim(new.pubgm_game_id),'') is not null then
  new.game_id_locked:=true;
 end if;
 return new;
end $$;

drop trigger if exists profiles_prevent_pubgm_game_id_change on public.profiles;
create trigger profiles_prevent_pubgm_game_id_change
before update of pubgm_game_id on public.profiles
for each row execute function public.prevent_pubgm_game_id_change();

revoke all on function public.prevent_pubgm_game_id_change() from public,anon,authenticated;

commit;

-- ===== END supabase/migrations/20261108230000_airdrop_pubgm_game_id_lock.sql =====


-- ===== BEGIN supabase/migrations/20261108240000_airdrop_pubgm_messaging_report_hardening.sql =====
-- AIRDROP PUBGM — tighten messaging and profile-report updates
-- Message recipients may mark messages as read, but cannot rewrite message content or identity.
-- Admins/moderators may update the review fields of player profile reports.

begin;

revoke update on public.player_messages from anon,authenticated;
grant update(read_at) on public.player_messages to authenticated;

drop policy if exists profile_reports_admin_update on public.player_profile_reports;
create policy profile_reports_admin_update on public.player_profile_reports for update to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')))
with check(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));
grant update(status,reviewed_by,reviewed_at) on public.player_profile_reports to authenticated;

commit;

-- ===== END supabase/migrations/20261108240000_airdrop_pubgm_messaging_report_hardening.sql =====


-- ===== BEGIN supabase/migrations/20261108250000_airdrop_pubgm_suspension_enforcement.sql =====
-- AIRDROP PUBGM — enforce account suspensions on new player activity
-- A suspended account cannot create activities, join them, post, comment, react, repost or send messages.

begin;

create or replace function public.airdrop_reject_suspended_player()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare
 raw_uid text;
 uid uuid;
 is_suspended boolean;
begin
 raw_uid:=coalesce(to_jsonb(new)->>'user_id',to_jsonb(new)->>'creator_id',to_jsonb(new)->>'sender_id');
 if raw_uid is null then return new; end if;
 uid:=raw_uid::uuid;
 select exists(
  select 1 from public.player_account_moderation m
  where m.user_id=uid and m.status='suspended'
    and (m.suspended_until is null or m.suspended_until>now())
 ) into is_suspended;
 if is_suspended then raise exception 'This account is suspended and cannot perform this action.'; end if;
 return new;
end $$;

drop trigger if exists activities_reject_suspended on public.activities;
create trigger activities_reject_suspended before insert on public.activities
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists participants_reject_suspended on public.participants;
create trigger participants_reject_suspended before insert on public.participants
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists feed_posts_reject_suspended on public.feed_posts;
create trigger feed_posts_reject_suspended before insert on public.feed_posts
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists feed_comments_reject_suspended on public.feed_comments;
create trigger feed_comments_reject_suspended before insert on public.feed_comments
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists feed_reactions_reject_suspended on public.feed_reactions;
create trigger feed_reactions_reject_suspended before insert on public.feed_reactions
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists feed_reposts_reject_suspended on public.feed_reposts;
create trigger feed_reposts_reject_suspended before insert on public.feed_reposts
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists player_messages_reject_suspended on public.player_messages;
create trigger player_messages_reject_suspended before insert on public.player_messages
for each row execute function public.airdrop_reject_suspended_player();

revoke all on function public.airdrop_reject_suspended_player() from public,anon,authenticated;

commit;

-- ===== END supabase/migrations/20261108250000_airdrop_pubgm_suspension_enforcement.sql =====

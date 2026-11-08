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

revoke all on public.activity_secrets from anon,authenticated;
revoke all on function public.get_activity_secret(uuid) from public;
revoke all on function public.create_activity(public.activity_type,text,text,text,timestamptz,integer,integer,text,text,text) from public;
grant execute on function public.get_activity_secret(uuid) to authenticated;
grant execute on function public.create_activity(public.activity_type,text,text,text,timestamptz,integer,integer,text,text,text) to authenticated;

commit;

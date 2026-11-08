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

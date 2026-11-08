-- AIRDROP PUBGM post-install verification
-- Run AFTER supabase/AIRDROP-PUBGM-SETUP.sql completes successfully.
-- Read-only checks; this script makes no database changes.

do $$
declare missing text[] := array[]::text[];
begin
 if to_regclass('public.profiles') is null then missing:=array_append(missing,'public.profiles'); end if;
 if to_regclass('public.public_profiles') is null then missing:=array_append(missing,'public.public_profiles'); end if;
 if to_regclass('public.activities') is null then missing:=array_append(missing,'public.activities'); end if;
 if to_regclass('public.activity_secrets') is null then missing:=array_append(missing,'public.activity_secrets'); end if;
 if to_regclass('public.participants') is null then missing:=array_append(missing,'public.participants'); end if;
 if to_regclass('public.tournament_matches') is null then missing:=array_append(missing,'public.tournament_matches'); end if;
 if to_regclass('public.feed_posts') is null then missing:=array_append(missing,'public.feed_posts'); end if;
 if to_regclass('public.player_messages') is null then missing:=array_append(missing,'public.player_messages'); end if;
 if to_regclass('public.player_follows') is null then missing:=array_append(missing,'public.player_follows'); end if;
 if to_regclass('public.player_notification_settings') is null then missing:=array_append(missing,'public.player_notification_settings'); end if;
 if to_regclass('public.credit_purchase_settings') is null then missing:=array_append(missing,'public.credit_purchase_settings'); end if;
 if to_regclass('public.withdrawal_settings') is null then missing:=array_append(missing,'public.withdrawal_settings'); end if;
 if to_regclass('public.notifications') is null then missing:=array_append(missing,'public.notifications'); end if;
 if to_regclass('public.player_notification_settings') is null then missing:=array_append(missing,'public.player_notification_settings'); end if;
 if to_regclass('public.player_profile_reports') is null then missing:=array_append(missing,'public.player_profile_reports'); end if;
 if to_regclass('public.player_message_reports') is null then missing:=array_append(missing,'public.player_message_reports'); end if;
 if to_regclass('public.player_account_moderation') is null then missing:=array_append(missing,'public.player_account_moderation'); end if;
 if to_regclass('public.profile_cosmetics') is null then missing:=array_append(missing,'public.profile_cosmetics'); end if;
 if to_regclass('public.admin_roles') is null then missing:=array_append(missing,'public.admin_roles'); end if;
 if to_regclass('public.profile_mission_level_settings') is null then missing:=array_append(missing,'public.profile_mission_level_settings'); end if;

 if to_regprocedure('public.create_activity(public.activity_type,text,text,text,timestamp with time zone,integer,integer,text,text,text)') is null then missing:=array_append(missing,'RPC create_activity'); end if;
 if to_regprocedure('public.join_activity(uuid)') is null then missing:=array_append(missing,'RPC join_activity'); end if;
 if to_regprocedure('public.get_activity_secret(uuid)') is null then missing:=array_append(missing,'RPC get_activity_secret'); end if;
 if to_regprocedure('public.seed_tournament(uuid)') is null then missing:=array_append(missing,'RPC seed_tournament'); end if;
 if to_regprocedure('public.admin_list_players()') is null then missing:=array_append(missing,'RPC admin_list_players'); end if;
 if to_regprocedure('public.admin_review_tournament_result(uuid,text,text)') is null then missing:=array_append(missing,'RPC admin_review_tournament_result'); end if;
 if not exists(select 1 from storage.buckets where id='avatars' and public=true) then missing:=array_append(missing,'public avatars storage bucket'); end if;
 if not exists(select 1 from storage.buckets where id='feed-media' and public=true) then missing:=array_append(missing,'public feed-media storage bucket'); end if;
 if not exists(select 1 from storage.buckets where id='tournament-evidence' and public=false) then missing:=array_append(missing,'private tournament-evidence storage bucket'); end if;
 if to_regprocedure('public.player_leaderboard(integer)') is null then missing:=array_append(missing,'RPC player_leaderboard'); end if;
 if to_regprocedure('public.get_community_feed(integer)') is null then missing:=array_append(missing,'RPC get_community_feed'); end if;
 if to_regprocedure('public.create_credit_purchase_request(integer,text)') is null then missing:=array_append(missing,'RPC create_credit_purchase_request'); end if;
 if to_regprocedure('public.airdrop_create_notification(uuid,text,text,text,uuid,uuid,uuid,text)') is null then missing:=array_append(missing,'RPC airdrop_create_notification'); end if;

 if cardinality(missing)>0 then
  raise exception 'AIRDROP PUBGM setup is incomplete. Missing: %',array_to_string(missing,', ');
 end if;

 if coalesce((select enabled from public.credit_purchase_settings where id=true),true) then
  raise exception 'Safety check failed: credit purchases must remain disabled.';
 end if;
 if coalesce((select enabled from public.withdrawal_settings where id=true),true) then
  raise exception 'Safety check failed: cash withdrawals must remain disabled.';
 end if;
 if not exists(select 1 from pg_class where oid=to_regclass('public.profiles') and relrowsecurity) then
  raise exception 'Security check failed: row-level security is not enabled on profiles.';
 end if;
 if not exists(select 1 from pg_class where oid=to_regclass('public.activity_secrets') and relrowsecurity) then
  raise exception 'Security check failed: row-level security is not enabled on activity_secrets.';
 end if;
 if not exists(select 1 from pg_trigger where tgrelid=to_regclass('auth.users') and tgname='on_auth_user_created_airdrop' and not tgisinternal) then
  raise exception 'Setup check failed: new-user profile trigger is missing.';
 end if;
 if not exists(select 1 from storage.buckets where id='avatars' and public=true) then
  raise exception 'Storage check failed: public avatars bucket is missing.';
 end if;
 if not exists(select 1 from storage.buckets where id='feed-media' and public=true) then
  raise exception 'Storage check failed: public feed-media bucket is missing.';
 end if;
 if not exists(select 1 from storage.buckets where id='tournament-evidence' and public=false) then
  raise exception 'Storage check failed: private tournament-evidence bucket is missing.';
 end if;
 if (select count(*) from public.profile_cosmetics where active=true)<10 then
  raise exception 'Store check failed: starter cosmetics have not been seeded.';
 end if;
 raise notice 'AIRDROP PUBGM schema, key RPC, RLS and new-user trigger checks passed. Payment settings remain disabled.';
end $$;

select
 (select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE') as public_tables,
 (select count(*) from information_schema.routines where specific_schema='public' and routine_type='FUNCTION') as public_functions,
 (select enabled from public.credit_purchase_settings where id=true) as credit_purchases_enabled,
 (select enabled from public.withdrawal_settings where id=true) as withdrawals_enabled,
 (select count(*) from public.profile_cosmetics where active=true) as active_cosmetics,
 (select count(*) from storage.buckets where id in ('avatars','feed-media','tournament-evidence')) as configured_storage_buckets;

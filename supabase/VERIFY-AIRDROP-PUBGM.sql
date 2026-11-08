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
 if to_regclass('public.credit_purchase_settings') is null then missing:=array_append(missing,'public.credit_purchase_settings'); end if;
 if to_regclass('public.withdrawal_settings') is null then missing:=array_append(missing,'public.withdrawal_settings'); end if;

 if to_regprocedure('public.create_activity(public.activity_type,text,text,text,timestamp with time zone,integer,integer,text,text,text)') is null then missing:=array_append(missing,'RPC create_activity'); end if;
 if to_regprocedure('public.join_activity(uuid)') is null then missing:=array_append(missing,'RPC join_activity'); end if;
 if to_regprocedure('public.get_activity_secret(uuid)') is null then missing:=array_append(missing,'RPC get_activity_secret'); end if;
 if to_regprocedure('public.seed_tournament(uuid)') is null then missing:=array_append(missing,'RPC seed_tournament'); end if;
 if to_regprocedure('public.admin_list_players()') is null then missing:=array_append(missing,'RPC admin_list_players'); end if;
 if to_regprocedure('public.admin_review_tournament_result(uuid,text,text)') is null then missing:=array_append(missing,'RPC admin_review_tournament_result'); end if;

 if cardinality(missing)>0 then
  raise exception 'AIRDROP PUBGM setup is incomplete. Missing: %',array_to_string(missing,', ');
 end if;

 if coalesce((select enabled from public.credit_purchase_settings where id=true),true) then
  raise exception 'Safety check failed: credit purchases must remain disabled.';
 end if;
 if coalesce((select enabled from public.withdrawal_settings where id=true),true) then
  raise exception 'Safety check failed: cash withdrawals must remain disabled.';
 end if;
 raise notice 'AIRDROP PUBGM core schema and required RPC checks passed. Payment settings remain disabled.';
end $$;

select
 (select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE') as public_tables,
 (select count(*) from information_schema.routines where specific_schema='public' and routine_type='FUNCTION') as public_functions,
 (select enabled from public.credit_purchase_settings where id=true) as credit_purchases_enabled,
 (select enabled from public.withdrawal_settings where id=true) as withdrawals_enabled;

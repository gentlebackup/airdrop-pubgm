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

-- AIRDROP PUBGM credit economy: enforce one purchased credit to create or join.
-- Development-only migration. Do not apply to production until reviewed and approved.
-- Existing activities, participants, wallets and ledger rows are not rewritten.
-- New activity creation atomically reserves 1 purchased credit and records it.
-- New activities carry a 1-credit entry fee; join_activity already performs an
-- atomic balance check and ledger insert only after a successful participant insert.

create or replace function public.create_activity(
  p_type public.activity_type,
  p_title text,
  p_room_code text,
  p_room_password text,
  p_scheduled_start timestamp with time zone,
  p_duration_minutes integer,
  p_capacity integer,
  p_game_mode text default null,
  p_map_name text default null,
  p_rules text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  uid uuid := auth.uid();
  aid uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if coalesce(length(trim(p_title)),0) < 3 then raise exception 'Activity title is required'; end if;
  if p_duration_minutes < 1 or p_duration_minutes > 720 then raise exception 'Activity duration is invalid'; end if;
  if p_capacity < 2 or p_capacity > 100 then raise exception 'Activity capacity is invalid'; end if;
  if p_scheduled_start <= now() then raise exception 'Start time must be in the future'; end if;

  update public.profiles
  set purchased_credits = purchased_credits - 1, updated_at = now()
  where id = uid and purchased_credits >= 1;
  if not found then raise exception 'Creating an activity costs 1 purchased credit. Please add credits to your wallet.'; end if;

  insert into public.activities(
    creator_id,type,title,scheduled_start,duration_minutes,capacity,
    game_mode,map_name,rules,entry_fee_credits
  )
  values(
    uid,p_type,trim(p_title),p_scheduled_start,p_duration_minutes,p_capacity,
    p_game_mode,p_map_name,p_rules,1
  )
  returning id into aid;

  insert into public.activity_secrets(activity_id,room_code,room_password)
  values(aid,p_room_code,p_room_password);

  insert into public.creation_token_transactions(user_id,amount,reason,activity_id)
  values(uid,-1,'credit_spent_activity_creation',aid);

  return aid;
end;
$function$;

create or replace function public.create_1v1_challenge(
  p_opponent_id uuid,
  p_title text,
  p_room_code text,
  p_room_password text,
  p_scheduled_start timestamp with time zone,
  p_duration_minutes integer,
  p_game_mode text default null,
  p_map_name text default null,
  p_rules text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  uid uuid := auth.uid();
  aid uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if p_opponent_id is null or p_opponent_id = uid then raise exception 'Choose a different opponent'; end if;
  if coalesce(length(trim(p_title)),0) < 3 then raise exception 'Challenge title is required'; end if;
  if p_duration_minutes < 1 or p_duration_minutes > 720 then raise exception 'Challenge duration is invalid'; end if;
  if p_scheduled_start <= now() then raise exception 'Start time must be in the future'; end if;
  if not exists(select 1 from public.profiles where id=p_opponent_id) then raise exception 'Opponent not found'; end if;

  update public.profiles
  set purchased_credits = purchased_credits - 1, updated_at = now()
  where id = uid and purchased_credits >= 1;
  if not found then raise exception 'Creating a 1v1 challenge costs 1 purchased credit. Please add credits to your wallet.'; end if;

  insert into public.activities(
    creator_id,type,title,scheduled_start,duration_minutes,capacity,
    game_mode,map_name,rules,entry_fee_credits
  )
  values(
    uid,'challenge_1v1',trim(p_title),p_scheduled_start,p_duration_minutes,2,
    p_game_mode,p_map_name,p_rules,1
  )
  returning id into aid;

  insert into public.activity_secrets(activity_id,room_code,room_password)
  values(aid,p_room_code,p_room_password);

  insert into public.challenges_1v1(activity_id,challenger_id,opponent_id,status)
  values(aid,uid,p_opponent_id,'pending');

  insert into public.creation_token_transactions(user_id,amount,reason,activity_id)
  values(uid,-1,'credit_spent_activity_creation',aid);

  return aid;
end;
$function$;

-- The public UI cannot change an activity's entry price away from the fixed
-- one-credit rule. Keep the RPC for compatibility with existing clients.
create or replace function public.set_activity_entry_fee(
  p_activity_id uuid,
  p_entry_fee_credits integer
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  uid uuid := auth.uid();
  is_admin boolean := false;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if p_entry_fee_credits is distinct from 1 then
    raise exception 'The entry fee is fixed at 1 credit per participant.';
  end if;
  select exists(
    select 1 from public.admin_roles r
    where r.user_id=uid and r.role in ('admin','super_admin')
  ) into is_admin;

  update public.activities a
  set entry_fee_credits=1,updated_at=now()
  where a.id=p_activity_id
    and (a.creator_id=uid or is_admin)
    and a.status='upcoming'
    and not exists(select 1 from public.participants p where p.activity_id=a.id);

  if not found then
    raise exception 'Only the creator or an administrator can set the fixed price before anyone joins an upcoming activity';
  end if;
end;
$function$;

revoke execute on function public.create_activity(public.activity_type,text,text,text,timestamp with time zone,integer,integer,text,text,text) from public, anon;
revoke execute on function public.create_1v1_challenge(uuid,text,text,text,timestamp with time zone,integer,text,text,text) from public, anon;
revoke execute on function public.set_activity_entry_fee(uuid,integer) from public, anon;
grant execute on function public.create_activity(public.activity_type,text,text,text,timestamp with time zone,integer,integer,text,text,text) to authenticated, service_role;
grant execute on function public.create_1v1_challenge(uuid,text,text,text,timestamp with time zone,integer,text,text,text) to authenticated, service_role;
grant execute on function public.set_activity_entry_fee(uuid,integer) to authenticated, service_role;

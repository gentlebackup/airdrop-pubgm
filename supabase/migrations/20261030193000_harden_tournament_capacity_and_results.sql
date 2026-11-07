-- AIRDROP PUBGM tournament hardening: only 4/8/16/32-player tournaments.
-- Ordinary activities retain their existing 2-100 capacity range.
-- Result submissions must include evidence and pass moderator/admin review.

begin;

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
) returns uuid
language plpgsql security definer set search_path to 'public'
as $function$
declare uid uuid := auth.uid(); aid uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if coalesce(length(trim(p_title)),0)<3 then raise exception 'Activity title is required'; end if;
  if p_duration_minutes<1 or p_duration_minutes>720 then raise exception 'Activity duration is invalid'; end if;
  if p_capacity<2 or p_capacity>100 then raise exception 'Activity capacity is invalid'; end if;
  if p_type='tournament' and p_capacity not in (4,8,16,32) then
    raise exception 'Tournament capacity must be 4, 8, 16 or 32 players';
  end if;
  if p_scheduled_start<=now() then raise exception 'Start time must be in the future'; end if;
  insert into public.activities(creator_id,type,title,scheduled_start,duration_minutes,capacity,game_mode,map_name,rules,entry_fee_credits)
  values(uid,p_type,trim(p_title),p_scheduled_start,p_duration_minutes,p_capacity,p_game_mode,p_map_name,p_rules,0)
  returning id into aid;
  insert into public.activity_secrets(activity_id,room_code,room_password) values(aid,p_room_code,p_room_password);
  return aid;
end $function$;

create or replace function public.create_tournament(
  p_title text,p_room_code text,p_room_password text,p_scheduled_start timestamptz,
  p_duration_minutes integer,p_capacity integer,p_game_mode text default null,
  p_map_name text default null,p_rules text default null
) returns uuid
language plpgsql security definer set search_path to 'public'
as $function$
declare uid uuid:=auth.uid(); aid uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if p_capacity not in (4,8,16,32) then raise exception 'Tournament capacity must be 4, 8, 16 or 32 players'; end if;
  if p_scheduled_start<=now() then raise exception 'Start time must be in the future'; end if;
  if p_duration_minutes<15 or p_duration_minutes>720 then raise exception 'Tournament duration is invalid'; end if;
  if coalesce(length(trim(p_title)),0)<3 then raise exception 'Tournament title is required'; end if;
  insert into public.activities(creator_id,type,title,scheduled_start,duration_minutes,capacity,game_mode,map_name,rules,entry_fee_credits)
  values(uid,'tournament',trim(p_title),p_scheduled_start,p_duration_minutes,p_capacity,p_game_mode,p_map_name,p_rules,0)
  returning id into aid;
  insert into public.activity_secrets(activity_id,room_code,room_password) values(aid,p_room_code,p_room_password);
  return aid;
end $function$;

create or replace function public.seed_tournament(p_activity_id uuid)
returns boolean language plpgsql security definer set search_path to 'public'
as $function$
declare
 uid uuid:=auth.uid(); a public.activities; stage_count int:=0; r int; m int; mc int;
 bracket_size int; bye_count int:=0; sid uuid; mid uuid; nm uuid; slot text;
 pids uuid[]; pi int:=1; pa uuid; pb uuid; participant_count int;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select * into a from public.activities where id=p_activity_id and type='tournament' and creator_id=uid for update;
 if not found then raise exception 'Tournament not found'; end if;
 if a.status not in('upcoming','check_in') then raise exception 'Tournament can no longer be seeded'; end if;
 if exists(select 1 from public.tournament_stages where activity_id=p_activity_id) then raise exception 'Tournament bracket already exists'; end if;
 if a.capacity not in (4,8,16,32) then raise exception 'Unsupported tournament capacity'; end if;
 select array_agg(user_id order by joined_at,id),count(*) into pids,participant_count
 from public.participants where activity_id=p_activity_id and status<>'removed';
 if coalesce(participant_count,0)<2 then raise exception 'At least 2 participants are required'; end if;
 if participant_count>a.capacity then raise exception 'Participant count exceeds tournament capacity'; end if;
 bracket_size:=1; while bracket_size<a.capacity loop bracket_size:=bracket_size*2; end loop;
 if participant_count>bracket_size/2 then bye_count:=bracket_size-participant_count; end if;
 mc:=bracket_size; while mc>1 loop stage_count:=stage_count+1; mc:=mc/2; end loop;
 for r in 1..stage_count loop
   mc:=bracket_size/power(2,r)::int;
   insert into public.tournament_stages(activity_id,stage_number,name)
   values(p_activity_id,r,case when mc=1 then 'Final' when mc=2 then 'Semifinal' when mc=4 then 'Quarterfinal' else 'Round of '||(mc*2) end)
   returning id into sid;
   for m in 1..mc loop
     pa:=null;pb:=null;
     if r=1 then
       if m<=bye_count then
         if pi<=participant_count then pa:=pids[pi];pi:=pi+1;end if;
       else
         if pi<=participant_count then pa:=pids[pi];pi:=pi+1;end if;
         if pi<=participant_count then pb:=pids[pi];pi:=pi+1;end if;
       end if;
     end if;
     insert into public.tournament_matches(stage_id,player_a,player_b,round_number,match_number,status)
     values(sid,pa,pb,r,m,'pending') returning id into mid;
   end loop;
 end loop;
 for r in 1..stage_count-1 loop
   mc:=bracket_size/power(2,r)::int;
   for m in 1..mc loop
     select tm.id into mid from public.tournament_matches tm join public.tournament_stages ts on ts.id=tm.stage_id
     where ts.activity_id=p_activity_id and tm.round_number=r and tm.match_number=m;
     select tm.id into nm from public.tournament_matches tm join public.tournament_stages ts on ts.id=tm.stage_id
     where ts.activity_id=p_activity_id and tm.round_number=r+1 and tm.match_number=((m+1)/2);
     slot:=case when mod(m,2)=1 then 'a' else 'b' end;
     update public.tournament_matches set next_match_id=nm,winner_slot=slot where id=mid;
   end loop;
 end loop;
 for r in 1..stage_count loop
   for mid in select tm.id from public.tournament_matches tm join public.tournament_stages ts on ts.id=tm.stage_id
     where ts.activity_id=p_activity_id and tm.round_number=r order by tm.match_number
   loop
     select player_a,player_b into pa,pb from public.tournament_matches where id=mid for update;
     if pa is not null and pb is null then update public.tournament_matches set winner_id=pa,status='completed' where id=mid and status='pending';
     elsif pa is null and pb is not null then update public.tournament_matches set winner_id=pb,status='completed' where id=mid and status='pending'; end if;
     select winner_id,next_match_id,winner_slot into pa,nm,slot from public.tournament_matches where id=mid;
     if pa is not null and nm is not null then
       if slot='a' then update public.tournament_matches set player_a=pa where id=nm and player_a is null;
       else update public.tournament_matches set player_b=pa where id=nm and player_b is null; end if;
     end if;
   end loop;
 end loop;
 return true;
end $function$;

create or replace function public.admin_review_tournament_result(
 p_report_id uuid,p_decision text,p_note text default null
) returns boolean language plpgsql security definer set search_path to 'public'
as $function$
declare uid uuid:=auth.uid(); r public.tournament_result_reports; m public.tournament_matches;
 s public.tournament_stages; a public.activities; nm public.tournament_matches;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(select 1 from public.admin_roles ar where ar.user_id=uid and ar.role in ('admin','moderator','super_admin','owner')) then raise exception 'Admin access required'; end if;
 if p_decision not in ('approved','rejected') then raise exception 'Invalid review decision'; end if;
 select * into r from public.tournament_result_reports where id=p_report_id for update;
 if not found or r.status<>'pending' then raise exception 'Pending result report not found'; end if;
 select * into m from public.tournament_matches where id=r.match_id for update;
 if not found or m.status<>'pending' then raise exception 'Match is no longer awaiting a result'; end if;
 if p_decision='approved' then
   if r.winner_id not in(m.player_a,m.player_b) then raise exception 'Reported winner is not in this match'; end if;
   select * into s from public.tournament_stages where id=m.stage_id;
   select * into a from public.activities where id=s.activity_id;
   update public.tournament_matches set winner_id=r.winner_id,status='completed' where id=m.id;
   if m.next_match_id is not null then
     select * into nm from public.tournament_matches where id=m.next_match_id for update;
     if nm.id is null then raise exception 'Next bracket match is missing'; end if;
     if m.winner_slot='a' then
       if nm.player_a is not null and nm.player_a<>r.winner_id then raise exception 'Next bracket slot is already occupied by another player'; end if;
       update public.tournament_matches set player_a=r.winner_id where id=nm.id and player_a is null;
     elsif m.winner_slot='b' then
       if nm.player_b is not null and nm.player_b<>r.winner_id then raise exception 'Next bracket slot is already occupied by another player'; end if;
       update public.tournament_matches set player_b=r.winner_id where id=nm.id and player_b is null;
     else raise exception 'Bracket advancement slot is missing'; end if;
   else
     update public.activities set status='completed' where id=a.id and status in('upcoming','check_in','live');
   end if;
 end if;
 update public.tournament_result_reports set status=p_decision,reviewed_by=uid,reviewed_at=now(),review_note=left(p_note,1000) where id=r.id;
 return true;
end $function$;

-- The current app submits evidence and relies on admin review. Disable the
-- legacy two-argument overload so it cannot complete matches directly.
revoke execute on function public.report_tournament_result(uuid,uuid) from public, anon, authenticated;

commit;

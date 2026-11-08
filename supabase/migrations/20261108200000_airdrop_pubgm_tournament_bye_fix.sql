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

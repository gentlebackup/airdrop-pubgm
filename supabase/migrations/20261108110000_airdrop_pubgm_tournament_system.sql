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

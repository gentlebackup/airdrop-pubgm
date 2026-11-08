-- AIRDROP PUBGM — final access rules for room secrets and followed-player feed

begin;

create or replace function public.get_activity_secret(p_activity_id uuid)
returns table(room_code text,room_password text)
language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid();
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if not exists(
  select 1 from public.activities a
  where a.id=p_activity_id and (
   a.creator_id=uid or exists(
    select 1 from public.participants p
    where p.activity_id=a.id and p.user_id=uid and p.status<>'cancelled'
   )
  )
 ) then raise exception 'Not authorized to view room details'; end if;
 return query select s.room_code,s.room_password
 from public.activity_secrets s where s.activity_id=p_activity_id;
end $$;

create or replace function public.get_community_feed(p_limit integer default 50)
returns table(
 event_id text,event_type text,user_id uuid,profile_name text,username text,
 avatar_url text,event_title text,event_detail text,occurred_at timestamptz
)
language sql stable security definer set search_path=public,pg_temp as $$
 select 'post:'||p.id::text,'post'::text,p.user_id,pp.profile_name,pp.username,pp.avatar_url,
        p.title,left(coalesce(p.description,''),220),p.created_at
 from public.feed_posts p
 join public.public_profiles pp on pp.id=p.user_id
 where p.is_hidden=false
   and (
    p.user_id=auth.uid()
    or exists(
     select 1 from public.player_follows f
     where f.follower_id=auth.uid() and f.following_id=p.user_id
    )
   )
 order by p.created_at desc
 limit greatest(1,least(coalesce(p_limit,50),100));
$$;

revoke all on function public.get_activity_secret(uuid) from public,anon;
revoke all on function public.get_community_feed(integer) from public,anon;
grant execute on function public.get_activity_secret(uuid) to authenticated;
grant execute on function public.get_community_feed(integer) to authenticated;

commit;

-- AIRDROP PUBGM — in-app notification events
-- Creates inbox notifications for direct messages, follows, feed interactions and activity joins.
-- This does not send web push; push delivery needs a separately configured server-side sender.

begin;

create or replace function public.airdrop_create_notification(
 p_user_id uuid,p_title text,p_body text,p_type text,
 p_actor_id uuid default null,p_activity_id uuid default null,p_message_id uuid default null,p_action_url text default null
) returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if p_user_id is null or p_user_id=p_actor_id then return; end if;
 insert into public.notifications(user_id,title,body,type,actor_id,activity_id,message_id,action_url)
 values(p_user_id,left(coalesce(p_title,'AIRDROP PUBGM'),120),left(coalesce(p_body,''),500),
        left(coalesce(p_type,'general'),40),p_actor_id,p_activity_id,p_message_id,left(p_action_url,500));
end $$;

create or replace function public.airdrop_notify_message()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare enabled_value boolean; actor_name text;
begin
 select coalesce(s.messages_enabled,true) into enabled_value
 from (select 1) q left join public.player_notification_settings s on s.user_id=new.recipient_id;
 if coalesce(enabled_value,true) then
  select coalesce(profile_name,username,'A player') into actor_name from public.public_profiles where id=new.sender_id;
  perform public.airdrop_create_notification(new.recipient_id,'New message',
   coalesce(actor_name,'A player')||' sent you a message.','message',new.sender_id,null,new.id,'/messages');
 end if;
 return new;
end $$;

create or replace function public.airdrop_notify_follow()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare enabled_value boolean; actor_name text;
begin
 select coalesce(s.social_enabled,true) into enabled_value
 from (select 1) q left join public.player_notification_settings s on s.user_id=new.following_id;
 if coalesce(enabled_value,true) then
  select coalesce(profile_name,username,'A player') into actor_name from public.public_profiles where id=new.follower_id;
  perform public.airdrop_create_notification(new.following_id,'New follower',
   coalesce(actor_name,'A player')||' started following you.','social',new.follower_id,null,null,'/community');
 end if;
 return new;
end $$;

create or replace function public.airdrop_notify_feed_comment()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare owner_id uuid; enabled_value boolean; actor_name text;
begin
 select user_id into owner_id from public.feed_posts where id=new.post_id and is_hidden=false;
 select coalesce(s.feed_enabled,true) into enabled_value
 from (select 1) q left join public.player_notification_settings s on s.user_id=owner_id;
 if owner_id is not null and coalesce(enabled_value,true) then
  select coalesce(profile_name,username,'A player') into actor_name from public.public_profiles where id=new.user_id;
  perform public.airdrop_create_notification(owner_id,'New comment',
   coalesce(actor_name,'A player')||' commented on your post.','feed',new.user_id,null,null,'/community');
 end if;
 return new;
end $$;

create or replace function public.airdrop_notify_feed_reaction()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare owner_id uuid; enabled_value boolean; actor_name text;
begin
 select user_id into owner_id from public.feed_posts where id=new.post_id and is_hidden=false;
 select coalesce(s.feed_enabled,true) into enabled_value
 from (select 1) q left join public.player_notification_settings s on s.user_id=owner_id;
 if owner_id is not null and coalesce(enabled_value,true) then
  select coalesce(profile_name,username,'A player') into actor_name from public.public_profiles where id=new.user_id;
  perform public.airdrop_create_notification(owner_id,'New reaction',
   coalesce(actor_name,'A player')||' liked your post.','feed',new.user_id,null,null,'/community');
 end if;
 return new;
end $$;

create or replace function public.airdrop_notify_feed_repost()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare owner_id uuid; enabled_value boolean; actor_name text;
begin
 select user_id into owner_id from public.feed_posts where id=new.post_id and is_hidden=false;
 select coalesce(s.feed_enabled,true) into enabled_value
 from (select 1) q left join public.player_notification_settings s on s.user_id=owner_id;
 if owner_id is not null and coalesce(enabled_value,true) then
  select coalesce(profile_name,username,'A player') into actor_name from public.public_profiles where id=new.user_id;
  perform public.airdrop_create_notification(owner_id,'Your post was shared',
   coalesce(actor_name,'A player')||' reposted your post.','feed',new.user_id,null,null,'/community');
 end if;
 return new;
end $$;

create or replace function public.airdrop_notify_activity_join()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare owner_id uuid; activity_title text; enabled_value boolean; actor_name text;
begin
 select a.creator_id,a.title into owner_id,activity_title
 from public.activities a where a.id=new.activity_id;
 select coalesce(s.activities_enabled,true) into enabled_value
 from (select 1) q left join public.player_notification_settings s on s.user_id=owner_id;
 if owner_id is not null and coalesce(enabled_value,true) then
  select coalesce(profile_name,username,'A player') into actor_name from public.public_profiles where id=new.user_id;
  perform public.airdrop_create_notification(owner_id,'New player joined',
   coalesce(actor_name,'A player')||' joined "'||coalesce(activity_title,'your activity')||'".',
   'activity',new.user_id,new.activity_id,null,'/activities');
 end if;
 return new;
end $$;

drop trigger if exists player_messages_notify_recipient on public.player_messages;
create trigger player_messages_notify_recipient after insert on public.player_messages
for each row execute function public.airdrop_notify_message();

drop trigger if exists player_follows_notify_following on public.player_follows;
create trigger player_follows_notify_following after insert on public.player_follows
for each row execute function public.airdrop_notify_follow();

drop trigger if exists feed_comments_notify_post_owner on public.feed_comments;
create trigger feed_comments_notify_post_owner after insert on public.feed_comments
for each row execute function public.airdrop_notify_feed_comment();

drop trigger if exists feed_reactions_notify_post_owner on public.feed_reactions;
create trigger feed_reactions_notify_post_owner after insert on public.feed_reactions
for each row execute function public.airdrop_notify_feed_reaction();

drop trigger if exists feed_reposts_notify_post_owner on public.feed_reposts;
create trigger feed_reposts_notify_post_owner after insert on public.feed_reposts
for each row execute function public.airdrop_notify_feed_repost();

drop trigger if exists participants_notify_activity_creator on public.participants;
create trigger participants_notify_activity_creator after insert on public.participants
for each row execute function public.airdrop_notify_activity_join();

revoke all on function public.airdrop_create_notification(uuid,text,text,text,uuid,uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.airdrop_notify_message() from public,anon,authenticated;
revoke all on function public.airdrop_notify_follow() from public,anon,authenticated;
revoke all on function public.airdrop_notify_feed_comment() from public,anon,authenticated;
revoke all on function public.airdrop_notify_feed_reaction() from public,anon,authenticated;
revoke all on function public.airdrop_notify_feed_repost() from public,anon,authenticated;
revoke all on function public.airdrop_notify_activity_join() from public,anon,authenticated;

commit;

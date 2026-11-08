-- AIRDROP PUBGM — community, follows, messaging and moderation tables
-- Phase 4. Complements the existing feed-media migration.

begin;

alter table public.feed_posts add column if not exists view_count bigint not null default 0;
alter table public.feed_comments add column if not exists parent_comment_id uuid references public.feed_comments(id) on delete cascade;

create table if not exists public.feed_post_views (
 post_id uuid not null references public.feed_posts(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 viewed_at timestamptz not null default now(),
 primary key(post_id,user_id)
);

create table if not exists public.player_follows (
 follower_id uuid not null references auth.users(id) on delete cascade,
 following_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(follower_id,following_id),
 check(follower_id<>following_id)
);

create table if not exists public.player_message_blocks (
 blocker_id uuid not null references auth.users(id) on delete cascade,
 blocked_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(blocker_id,blocked_id),
 check(blocker_id<>blocked_id)
);

create table if not exists public.player_messages (
 id uuid primary key default gen_random_uuid(),
 sender_id uuid not null references auth.users(id) on delete cascade,
 recipient_id uuid not null references auth.users(id) on delete cascade,
 body text not null check(char_length(trim(body)) between 1 and 4000),
 created_at timestamptz not null default now(),
 read_at timestamptz,
 check(sender_id<>recipient_id)
);
create index if not exists player_messages_thread_idx on public.player_messages(sender_id,recipient_id,created_at desc);
create index if not exists player_messages_recipient_idx on public.player_messages(recipient_id,created_at desc);

create table if not exists public.player_message_reports (
 id uuid primary key default gen_random_uuid(),
 reporter_id uuid not null references auth.users(id) on delete cascade,
 message_id uuid not null references public.player_messages(id) on delete cascade,
 reason text not null,
 details text,
 status text not null default 'open' check(status in('open','reviewing','resolved','dismissed')),
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 created_at timestamptz not null default now()
);

create table if not exists public.player_profile_reports (
 id uuid primary key default gen_random_uuid(),
 reporter_id uuid not null references auth.users(id) on delete cascade,
 reported_user_id uuid not null references auth.users(id) on delete cascade,
 reason text not null,
 details text,
 status text not null default 'open' check(status in('open','reviewing','resolved','dismissed')),
 reviewed_by uuid references auth.users(id) on delete set null,
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 check(reporter_id<>reported_user_id)
);

create table if not exists public.player_verifications (
 user_id uuid primary key references auth.users(id) on delete cascade,
 verified_by uuid references auth.users(id) on delete set null,
 verified_at timestamptz not null default now()
);

create table if not exists public.player_account_moderation (
 user_id uuid primary key references auth.users(id) on delete cascade,
 status text not null default 'active' check(status in('active','suspended')),
 reason text,
 suspended_until timestamptz,
 updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default now()
);

create table if not exists public.player_moderation_history (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 admin_id uuid references auth.users(id) on delete set null,
 action text not null,
 reason text,
 created_at timestamptz not null default now()
);

create table if not exists public.player_notification_settings (
 user_id uuid primary key references auth.users(id) on delete cascade,
 push_enabled boolean not null default true,
 messages_enabled boolean not null default true,
 social_enabled boolean not null default true,
 announcements_enabled boolean not null default true,
 sound_enabled boolean not null default true,
 sound_volume integer not null default 65 check(sound_volume between 0 and 100),
 activities_enabled boolean not null default true,
 tournaments_enabled boolean not null default true,
 wallet_enabled boolean not null default true,
 missions_enabled boolean not null default true,
 feed_enabled boolean not null default true,
 live_enabled boolean not null default true,
 security_enabled boolean not null default true,
 updated_at timestamptz not null default now()
);

create table if not exists public.live_streams (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 title text not null,
 youtube_url text,
 youtube_video_id text,
 status text not null default 'live' check(status in('live','ended')),
 created_at timestamptz not null default now(),
 ended_at timestamptz,
 platform text not null default 'youtube',
 stream_url text
);

-- Feed view count is deduplicated per signed-in player.
create or replace function public.record_feed_post_view(p_post_id uuid)
returns bigint language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid:=auth.uid(); total bigint;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 insert into public.feed_post_views(post_id,user_id)
 select p.id,uid from public.feed_posts p where p.id=p_post_id and p.is_hidden=false
 on conflict(post_id,user_id) do nothing;
 if not found then
   if not exists(select 1 from public.feed_posts where id=p_post_id and is_hidden=false) then raise exception 'Post not found'; end if;
 else
   update public.feed_posts set view_count=view_count+1 where id=p_post_id;
 end if;
 select view_count into total from public.feed_posts where id=p_post_id;
 return coalesce(total,0);
end $$;

-- Community activity stream exposes only a safe subset of profile data.
create or replace function public.get_community_feed(p_limit integer default 50)
returns table(event_id text,event_type text,user_id uuid,profile_name text,username text,avatar_url text,event_title text,event_detail text,occurred_at timestamptz)
language sql stable security definer set search_path=public,pg_temp as $$
 select 'post:'||p.id::text,'post'::text,p.user_id,pp.profile_name,pp.username,pp.avatar_url,
        p.title,left(coalesce(p.description,''),220),p.created_at
 from public.feed_posts p join public.public_profiles pp on pp.id=p.user_id
 where p.is_hidden=false
 order by p.created_at desc
 limit greatest(1,least(coalesce(p_limit,50),100));
$$;

alter table public.feed_post_views enable row level security;
alter table public.player_follows enable row level security;
alter table public.player_message_blocks enable row level security;
alter table public.player_messages enable row level security;
alter table public.player_message_reports enable row level security;
alter table public.player_profile_reports enable row level security;
alter table public.player_verifications enable row level security;
alter table public.player_account_moderation enable row level security;
alter table public.player_moderation_history enable row level security;
alter table public.player_notification_settings enable row level security;
alter table public.live_streams enable row level security;

drop policy if exists feed_views_read_own on public.feed_post_views;
create policy feed_views_read_own on public.feed_post_views for select to authenticated using(user_id=auth.uid());
drop policy if exists follows_read_involved on public.player_follows;
create policy follows_read_involved on public.player_follows for select to authenticated using(follower_id=auth.uid() or following_id=auth.uid());
drop policy if exists follows_insert_self on public.player_follows;
create policy follows_insert_self on public.player_follows for insert to authenticated with check(follower_id=auth.uid());
drop policy if exists follows_delete_self on public.player_follows;
create policy follows_delete_self on public.player_follows for delete to authenticated using(follower_id=auth.uid());

drop policy if exists blocks_read_involved on public.player_message_blocks;
create policy blocks_read_involved on public.player_message_blocks for select to authenticated using(blocker_id=auth.uid() or blocked_id=auth.uid());
drop policy if exists blocks_insert_self on public.player_message_blocks;
create policy blocks_insert_self on public.player_message_blocks for insert to authenticated with check(blocker_id=auth.uid());
drop policy if exists blocks_delete_self on public.player_message_blocks;
create policy blocks_delete_self on public.player_message_blocks for delete to authenticated using(blocker_id=auth.uid());

drop policy if exists messages_read_participants on public.player_messages;
create policy messages_read_participants on public.player_messages for select to authenticated using(sender_id=auth.uid() or recipient_id=auth.uid());
drop policy if exists messages_send_self on public.player_messages;
create policy messages_send_self on public.player_messages for insert to authenticated with check(sender_id=auth.uid() and not exists(select 1 from public.player_message_blocks b where b.blocker_id=recipient_id and b.blocked_id=auth.uid()) and not exists(select 1 from public.player_message_blocks b where b.blocker_id=auth.uid() and b.blocked_id=recipient_id));
drop policy if exists messages_recipient_read_update on public.player_messages;
create policy messages_recipient_read_update on public.player_messages for update to authenticated using(recipient_id=auth.uid()) with check(recipient_id=auth.uid());

drop policy if exists message_reports_insert_self on public.player_message_reports;
create policy message_reports_insert_self on public.player_message_reports for insert to authenticated with check(reporter_id=auth.uid());
drop policy if exists message_reports_read_self_or_admin on public.player_message_reports;
create policy message_reports_read_self_or_admin on public.player_message_reports for select to authenticated using(reporter_id=auth.uid() or exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));

drop policy if exists profile_reports_insert_self on public.player_profile_reports;
create policy profile_reports_insert_self on public.player_profile_reports for insert to authenticated with check(reporter_id=auth.uid());
drop policy if exists profile_reports_read_self_or_admin on public.player_profile_reports;
create policy profile_reports_read_self_or_admin on public.player_profile_reports for select to authenticated using(reporter_id=auth.uid() or exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));

drop policy if exists verifications_read_authenticated on public.player_verifications;
create policy verifications_read_authenticated on public.player_verifications for select to authenticated using(true);
drop policy if exists moderation_read_self on public.player_account_moderation;
create policy moderation_read_self on public.player_account_moderation for select to authenticated using(user_id=auth.uid());
drop policy if exists moderation_history_read_self on public.player_moderation_history;
create policy moderation_history_read_self on public.player_moderation_history for select to authenticated using(user_id=auth.uid());
drop policy if exists notification_settings_read_self on public.player_notification_settings;
create policy notification_settings_read_self on public.player_notification_settings for select to authenticated using(user_id=auth.uid());
drop policy if exists notification_settings_insert_self on public.player_notification_settings;
create policy notification_settings_insert_self on public.player_notification_settings for insert to authenticated with check(user_id=auth.uid());
drop policy if exists notification_settings_update_self on public.player_notification_settings;
create policy notification_settings_update_self on public.player_notification_settings for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

drop policy if exists live_streams_read_authenticated on public.live_streams;
create policy live_streams_read_authenticated on public.live_streams for select to authenticated using(true);
drop policy if exists live_streams_owner_insert on public.live_streams;
create policy live_streams_owner_insert on public.live_streams for insert to authenticated with check(user_id=auth.uid());
drop policy if exists live_streams_owner_update on public.live_streams;
create policy live_streams_owner_update on public.live_streams for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists live_streams_owner_delete on public.live_streams;
create policy live_streams_owner_delete on public.live_streams for delete to authenticated using(user_id=auth.uid());

grant select on public.feed_post_views,public.player_follows,public.player_message_blocks,public.player_messages,
 public.player_message_reports,public.player_profile_reports,public.player_verifications,
 public.player_account_moderation,public.player_moderation_history,public.player_notification_settings,public.live_streams
 to authenticated;
grant insert,delete on public.player_follows,public.player_message_blocks to authenticated;
grant select,insert,update on public.player_messages to authenticated;
grant insert on public.player_message_reports,public.player_profile_reports to authenticated;
grant insert,update on public.player_notification_settings to authenticated;
grant select,insert,update,delete on public.live_streams to authenticated;

revoke all on function public.record_feed_post_view(uuid) from public,anon;
revoke all on function public.get_community_feed(integer) from public,anon;
grant execute on function public.record_feed_post_view(uuid) to authenticated;
grant execute on function public.get_community_feed(integer) to authenticated;

commit;

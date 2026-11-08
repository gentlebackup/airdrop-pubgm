-- AIRDROP PUBGM — enforce account suspensions on new player activity
-- A suspended account cannot create activities, join them, post, comment, react, repost or send messages.

begin;

create or replace function public.airdrop_reject_suspended_player()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare
 raw_uid text;
 uid uuid;
 is_suspended boolean;
begin
 raw_uid:=coalesce(to_jsonb(new)->>'user_id',to_jsonb(new)->>'creator_id',to_jsonb(new)->>'sender_id');
 if raw_uid is null then return new; end if;
 uid:=raw_uid::uuid;
 select exists(
  select 1 from public.player_account_moderation m
  where m.user_id=uid and m.status='suspended'
    and (m.suspended_until is null or m.suspended_until>now())
 ) into is_suspended;
 if is_suspended then raise exception 'This account is suspended and cannot perform this action.'; end if;
 return new;
end $$;

drop trigger if exists activities_reject_suspended on public.activities;
create trigger activities_reject_suspended before insert on public.activities
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists participants_reject_suspended on public.participants;
create trigger participants_reject_suspended before insert on public.participants
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists feed_posts_reject_suspended on public.feed_posts;
create trigger feed_posts_reject_suspended before insert on public.feed_posts
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists feed_comments_reject_suspended on public.feed_comments;
create trigger feed_comments_reject_suspended before insert on public.feed_comments
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists feed_reactions_reject_suspended on public.feed_reactions;
create trigger feed_reactions_reject_suspended before insert on public.feed_reactions
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists feed_reposts_reject_suspended on public.feed_reposts;
create trigger feed_reposts_reject_suspended before insert on public.feed_reposts
for each row execute function public.airdrop_reject_suspended_player();

drop trigger if exists player_messages_reject_suspended on public.player_messages;
create trigger player_messages_reject_suspended before insert on public.player_messages
for each row execute function public.airdrop_reject_suspended_player();

revoke all on function public.airdrop_reject_suspended_player() from public,anon,authenticated;

commit;

-- AIRDROP PUBGM social feed: posts, media, comments, likes and reposts.
-- Development branch only; no production migration has been applied.
-- Posts and interactions are retained independently from existing player/account data.

create table if not exists public.feed_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 140),
  description text not null default '' check (char_length(description) <= 5000),
  hashtags text[] not null default '{}',
  media_path text,
  media_type text check (media_type in ('image','video') or media_type is null),
  media_mime_type text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  is_hidden boolean not null default false
);
create index if not exists feed_posts_created_idx on public.feed_posts(created_at desc) where is_hidden=false;
create index if not exists feed_posts_user_created_idx on public.feed_posts(user_id,created_at desc) where is_hidden=false;

create table if not exists public.feed_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.feed_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  is_hidden boolean not null default false
);
create index if not exists feed_comments_post_idx on public.feed_comments(post_id,created_at asc) where is_hidden=false;

create table if not exists public.feed_reactions (
  post_id uuid not null references public.feed_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  reaction text not null default 'like' check (reaction in ('like')),
  created_at timestamptz not null default now(),
  primary key(post_id,user_id)
);

create table if not exists public.feed_reposts (
  post_id uuid not null references public.feed_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(post_id,user_id)
);

alter table public.feed_posts enable row level security;
alter table public.feed_comments enable row level security;
alter table public.feed_reactions enable row level security;
alter table public.feed_reposts enable row level security;

drop policy if exists "feed posts public read" on public.feed_posts;
create policy "feed posts public read" on public.feed_posts for select to authenticated using (is_hidden=false);
drop policy if exists "feed posts owner insert" on public.feed_posts;
create policy "feed posts owner insert" on public.feed_posts for insert to authenticated with check (auth.uid()=user_id);
drop policy if exists "feed posts owner update" on public.feed_posts;
create policy "feed posts owner update" on public.feed_posts for update to authenticated using (auth.uid()=user_id) with check (auth.uid()=user_id);
drop policy if exists "feed posts owner delete" on public.feed_posts;
create policy "feed posts owner delete" on public.feed_posts for delete to authenticated using (auth.uid()=user_id);

drop policy if exists "feed comments read" on public.feed_comments;
create policy "feed comments read" on public.feed_comments for select to authenticated using (is_hidden=false);
drop policy if exists "feed comments own insert" on public.feed_comments;
create policy "feed comments own insert" on public.feed_comments for insert to authenticated with check (auth.uid()=user_id and exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed comments owner delete" on public.feed_comments;
create policy "feed comments owner delete" on public.feed_comments for delete to authenticated using (auth.uid()=user_id);

drop policy if exists "feed reactions read" on public.feed_reactions;
create policy "feed reactions read" on public.feed_reactions for select to authenticated using (exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed reactions own insert" on public.feed_reactions;
create policy "feed reactions own insert" on public.feed_reactions for insert to authenticated with check (auth.uid()=user_id and exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed reactions own delete" on public.feed_reactions;
create policy "feed reactions own delete" on public.feed_reactions for delete to authenticated using (auth.uid()=user_id);

drop policy if exists "feed reposts read" on public.feed_reposts;
create policy "feed reposts read" on public.feed_reposts for select to authenticated using (exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed reposts own insert" on public.feed_reposts;
create policy "feed reposts own insert" on public.feed_reposts for insert to authenticated with check (auth.uid()=user_id and exists(select 1 from public.feed_posts p where p.id=post_id and p.is_hidden=false));
drop policy if exists "feed reposts own delete" on public.feed_reposts;
create policy "feed reposts own delete" on public.feed_reposts for delete to authenticated using (auth.uid()=user_id);

grant select,insert,update,delete on public.feed_posts to authenticated;
grant select,insert,delete on public.feed_comments to authenticated;
grant select,insert,delete on public.feed_reactions to authenticated;
grant select,insert,delete on public.feed_reposts to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('feed-media','feed-media',true,104857600,array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime'])
on conflict(id) do update set public=true,file_size_limit=104857600,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "feed media public read" on storage.objects;
create policy "feed media public read" on storage.objects for select to public using (bucket_id='feed-media');
drop policy if exists "feed media owner upload" on storage.objects;
create policy "feed media owner upload" on storage.objects for insert to authenticated with check (bucket_id='feed-media' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "feed media owner update" on storage.objects;
create policy "feed media owner update" on storage.objects for update to authenticated using (bucket_id='feed-media' and (storage.foldername(name))[1]=auth.uid()::text) with check (bucket_id='feed-media' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "feed media owner delete" on storage.objects;
create policy "feed media owner delete" on storage.objects for delete to authenticated using (bucket_id='feed-media' and (storage.foldername(name))[1]=auth.uid()::text);

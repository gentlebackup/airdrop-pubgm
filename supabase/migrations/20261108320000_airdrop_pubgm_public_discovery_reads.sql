-- AIRDROP PUBGM — public discovery reads
-- Public stream cards and the season trailer are intentionally visible before sign-in.
-- Only currently live streams are exposed to anonymous visitors.

begin;

drop policy if exists live_streams_read_authenticated on public.live_streams;
drop policy if exists live_streams_read_public on public.live_streams;
create policy live_streams_read_public
on public.live_streams
for select
to anon, authenticated
using (status = 'live' and ended_at is null);

grant select on public.live_streams to anon, authenticated;

drop policy if exists site_media_read_authenticated on public.site_media_settings;
drop policy if exists site_media_read_public on public.site_media_settings;
create policy site_media_read_public
on public.site_media_settings
for select
to anon, authenticated
using (true);

grant select (id, trailer_video_url, trailer_thumbnail_url, trailer_title)
on public.site_media_settings to anon;

commit;

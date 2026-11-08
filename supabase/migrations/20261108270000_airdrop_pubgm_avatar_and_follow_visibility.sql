-- AIRDROP PUBGM — public avatar storage and visible follow graph
-- Avatars are public profile media; players may manage only files in their own UID folder.
-- Follow relationships are visible to signed-in players for profile counts and friend lists.

begin;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('avatars','avatars',true,2097152,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update set public=true,file_size_limit=2097152,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists airdrop_avatars_public_read on storage.objects;
create policy airdrop_avatars_public_read on storage.objects
for select to public using(bucket_id='avatars');

drop policy if exists airdrop_avatars_owner_upload on storage.objects;
create policy airdrop_avatars_owner_upload on storage.objects
for insert to authenticated
with check(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists airdrop_avatars_owner_update on storage.objects;
create policy airdrop_avatars_owner_update on storage.objects
for update to authenticated
using(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text)
with check(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists airdrop_avatars_owner_delete on storage.objects;
create policy airdrop_avatars_owner_delete on storage.objects
for delete to authenticated
using(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists follows_read_involved on public.player_follows;
drop policy if exists follows_read_authenticated on public.player_follows;
create policy follows_read_authenticated on public.player_follows
for select to authenticated using(true);

commit;

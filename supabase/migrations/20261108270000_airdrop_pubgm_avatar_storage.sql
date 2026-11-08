-- AIRDROP PUBGM — profile avatar storage bucket
-- Public read is intentional because profile avatars appear in public player cards.
-- Upload, replacement and deletion are restricted to the authenticated owner's folder.

begin;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('avatars','avatars',true,2097152,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update
set public=true,file_size_limit=2097152,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "AIRDROP avatar public read" on storage.objects;
create policy "AIRDROP avatar public read" on storage.objects
for select to public using(bucket_id='avatars');

drop policy if exists "AIRDROP avatar owner upload" on storage.objects;
create policy "AIRDROP avatar owner upload" on storage.objects
for insert to authenticated
with check(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists "AIRDROP avatar owner update" on storage.objects;
create policy "AIRDROP avatar owner update" on storage.objects
for update to authenticated
using(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text)
with check(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists "AIRDROP avatar owner delete" on storage.objects;
create policy "AIRDROP avatar owner delete" on storage.objects
for delete to authenticated
using(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);

commit;

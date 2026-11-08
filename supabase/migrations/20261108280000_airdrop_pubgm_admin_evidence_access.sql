-- AIRDROP PUBGM — allow admins to inspect private tournament evidence
-- Players can still read only their own uploads; admins may read evidence for review.

begin;

drop policy if exists tournament_evidence_admin_read on storage.objects;
create policy tournament_evidence_admin_read on storage.objects
for select to authenticated
using (
 bucket_id='tournament-evidence'
 and exists(
  select 1 from public.admin_roles r
  where r.user_id=auth.uid()
    and r.role in('admin','moderator','super_admin','owner')
 )
);

commit;

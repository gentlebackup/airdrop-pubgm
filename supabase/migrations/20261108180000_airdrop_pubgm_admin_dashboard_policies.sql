-- AIRDROP PUBGM — admin-only direct-table access required by the admin dashboard

begin;

drop policy if exists profiles_admin_read on public.profiles;
create policy profiles_admin_read on public.profiles for select to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));

drop policy if exists verification_admin_insert on public.player_verifications;
create policy verification_admin_insert on public.player_verifications for insert to authenticated
with check(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')));
drop policy if exists verification_admin_delete on public.player_verifications;
create policy verification_admin_delete on public.player_verifications for delete to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')));

drop policy if exists moderation_admin_read on public.player_account_moderation;
create policy moderation_admin_read on public.player_account_moderation for select to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')));

drop policy if exists message_reports_admin_read on public.player_message_reports;
create policy message_reports_admin_read on public.player_message_reports for select to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));

drop policy if exists site_media_admin_update on public.site_media_settings;
create policy site_media_admin_update on public.site_media_settings for update to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')))
with check(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','super_admin','owner')));

grant select on public.profiles,public.player_account_moderation,public.player_message_reports to authenticated;
grant insert,delete on public.player_verifications to authenticated;
grant update(trailer_video_url,trailer_thumbnail_url,trailer_title,updated_by,updated_at)
on public.site_media_settings to authenticated;

commit;

-- AIRDROP PUBGM — tighten messaging and profile-report updates
-- Message recipients may mark messages as read, but cannot rewrite message content or identity.
-- Admins/moderators may update the review fields of player profile reports.

begin;

revoke update on public.player_messages from anon,authenticated;
grant update(read_at) on public.player_messages to authenticated;

drop policy if exists profile_reports_admin_update on public.player_profile_reports;
create policy profile_reports_admin_update on public.player_profile_reports for update to authenticated
using(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')))
with check(exists(select 1 from public.admin_roles r where r.user_id=auth.uid() and r.role in('admin','moderator','super_admin','owner')));
grant update(status,reviewed_by,reviewed_at) on public.player_profile_reports to authenticated;

commit;

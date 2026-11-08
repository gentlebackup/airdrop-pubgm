-- AIRDROP PUBGM — allow players to submit message reports, with admin-only review access

begin;
drop policy if exists message_reports_insert_self on public.player_message_reports;
create policy message_reports_insert_self on public.player_message_reports for insert to authenticated
with check(reporter_id=auth.uid() and exists(select 1 from public.player_messages m where m.id=message_id and (m.sender_id=auth.uid() or m.recipient_id=auth.uid())));
grant insert on public.player_message_reports to authenticated;
revoke update,delete on public.player_message_reports from anon,authenticated;
commit;

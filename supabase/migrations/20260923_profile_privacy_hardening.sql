-- AIRDROP PUBGM profile privacy hardening
-- Keep private account fields in profiles; expose only safe discovery fields through public_profiles.

create or replace view public.public_profiles
with (security_invoker = false)
as
select id, profile_name, username, region, game_name, avatar_url
from public.profiles;

revoke all on public.public_profiles from anon;
revoke all on public.public_profiles from authenticated;
grant select on public.public_profiles to authenticated;

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id);

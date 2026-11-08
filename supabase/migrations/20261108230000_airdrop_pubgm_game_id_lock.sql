-- AIRDROP PUBGM — lock PUBG Mobile account ID after first save
-- Users may set an empty game ID once; they cannot later replace or clear it.

begin;

create or replace function public.prevent_pubgm_game_id_change()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if old.pubgm_game_id is not null
    and nullif(trim(old.pubgm_game_id),'') is not null
    and new.pubgm_game_id is distinct from old.pubgm_game_id then
  raise exception 'Your PUBG Mobile ID is locked and cannot be changed.';
 end if;
 if old.pubgm_game_id is null and nullif(trim(new.pubgm_game_id),'') is not null then
  new.game_id_locked:=true;
 end if;
 return new;
end $$;

drop trigger if exists profiles_prevent_pubgm_game_id_change on public.profiles;
create trigger profiles_prevent_pubgm_game_id_change
before update of pubgm_game_id on public.profiles
for each row execute function public.prevent_pubgm_game_id_change();

revoke all on function public.prevent_pubgm_game_id_change() from public,anon,authenticated;

commit;

-- AIRDROP PUBGM — starter achievement catalogue
-- Requirements use the requirement_type values handled by refresh_user_achievements().

begin;

insert into public.achievements(code,name,description,icon,requirement_type,requirement_value)
values
 ('first_drop','First Drop','Complete your first verified activity.','🪂','matches_completed',1),
 ('warmup_warrior','Warm-up Warrior','Complete 5 verified activities.','🎯','matches_completed',5),
 ('clutch_player','Clutch Player','Complete 10 verified activities.','🔥','matches_completed',10),
 ('squad_veteran','Squad Veteran','Complete 25 verified activities.','🛡️','matches_completed',25),
 ('tournament_debut','Tournament Debut','Join your first tournament.','🏆','tournaments_joined',1),
 ('bracket_climber','Bracket Climber','Join 5 tournaments.','🥇','tournaments_joined',5),
 ('host_commander','Host Commander','Create your first tournament.','🎖️','tournaments_created',1),
 ('challenge_accepted','Challenge Accepted','Complete your first 1v1 challenge.','⚔️','challenges_completed',1),
 ('duel_specialist','Duel Specialist','Complete 10 1v1 challenges.','👑','challenges_completed',10)
on conflict(code) do nothing;

commit;

-- AIRDROP PUBGM — starter cosmetic catalogue
-- Seed only stable catalog IDs; existing rows are left unchanged on reruns.

begin;

insert into public.profile_cosmetics(code,name,category,description,price_credits,style_key,active,sort_order)
values
 ('pubgm_name_neon_strike','Neon Strike','name_style','A bright competitive name treatment.',120,'neon-strike',true,10),
 ('pubgm_name_royal_gold','Royal Gold','name_style','A premium gold name treatment.',180,'royal-gold',true,20),
 ('pubgm_name_ice_frost','Ice Frost','name_style','A cool icy name treatment.',180,'ice-frost',true,30),
 ('pubgm_name_galaxy_crown','Galaxy Crown','name_style','A cosmic champion name treatment.',350,'galaxy-crown',true,40),
 ('pubgm_frame_tactical','Tactical Frame','profile_frame','A clean tactical profile frame.',200,'tactical-frame',true,50),
 ('pubgm_frame_legend','Legend Frame','profile_frame','A bold frame for top players.',350,'legend-frame',true,60),
 ('pubgm_frame_royal_crown','Royal Crown Frame','profile_frame','A crown-inspired elite frame.',450,'royal-crown-frame',true,70),
 ('pubgm_theme_neon_circuit','Neon Circuit','profile_theme','A glowing neon profile theme.',500,'neon-circuit',true,80),
 ('pubgm_theme_frost_dominion','Frost Dominion','profile_theme','A cool blue competitive theme.',500,'frost-dominion',true,90),
 ('pubgm_theme_crimson_onslaught','Crimson Onslaught','profile_theme','A bold crimson profile theme.',500,'crimson-onslaught',true,100),
 ('pubgm_effect_pulse','Pulse Avatar','avatar_effect','A subtle animated avatar pulse.',250,'pulse-avatar',true,110),
 ('pubgm_effect_golden_pulse','Golden Pulse','avatar_effect','A premium golden avatar effect.',400,'golden-pulse-avatar',true,120),
 ('pubgm_effect_electric','Electric Avatar','avatar_effect','An electric avatar highlight.',350,'electric-avatar',true,130)
on conflict(code) do nothing;

commit;

begin;

create or replace function public.create_1v1_challenge(
  p_opponent_id uuid,
  p_activity_id uuid default null,
  p_message text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  challenge_id uuid;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;

  if p_opponent_id is null or p_opponent_id = uid then
    raise exception 'Invalid opponent';
  end if;

  if not exists (
    select 1 from public.profiles where id = p_opponent_id
  ) then
    raise exception 'Opponent not found';
  end if;

  insert into public.challenges_1v1 (
    creator_id,
    opponent_id,
    activity_id,
    message,
    status
  )
  values (
    uid,
    p_opponent_id,
    p_activity_id,
    left(coalesce(p_message, ''), 500),
    'pending'
  )
  returning id into challenge_id;

  return challenge_id;
end;
$$;

create or replace function public.create_activity(
  p_title text,
  p_description text default null,
  p_game text default 'PUBG Mobile',
  p_start_time timestamptz default null,
  p_duration_minutes integer default 60,
  p_capacity integer default 10,
  p_region text default null,
  p_mode text default null,
  p_secret text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  activity_id uuid;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;

  if length(trim(coalesce(p_title, ''))) < 3 then
    raise exception 'Title must be at least 3 characters';
  end if;

  if p_duration_minutes < 1 or p_duration_minutes > 720 then
    raise exception 'Invalid duration';
  end if;

  if p_capacity < 2 or p_capacity > 100 then
    raise exception 'Invalid capacity';
  end if;

  if p_start_time is null or p_start_time <= now() then
    raise exception 'Start time must be in the future';
  end if;

  if not exists (
    select 1
    from public.profiles
    where id = uid
      and creation_tokens > 0
  ) then
    raise exception 'No creation token available';
  end if;

  insert into public.activities (
    creator_id,
    title,
    description,
    game,
    start_time,
    duration_minutes,
    capacity,
    region,
    mode,
    status
  )
  values (
    uid,
    left(trim(p_title), 120),
    left(coalesce(p_description, ''), 2000),
    left(coalesce(p_game, 'PUBG Mobile'), 120),
    p_start_time,
    p_duration_minutes,
    p_capacity,
    left(coalesce(p_region, ''), 100),
    left(coalesce(p_mode, ''), 100),
    'upcoming'
  )
  returning id into activity_id;

  return activity_id;
end;
$$;

create or replace function public.edit_activity(
  p_activity_id uuid,
  p_title text default null,
  p_description text default null,
  p_start_time timestamptz default null,
  p_duration_minutes integer default null,
  p_capacity integer default null,
  p_region text default null,
  p_mode text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  a public.activities;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;

  select * into a
  from public.activities
  where id = p_activity_id
  for update;

  if not found or a.creator_id <> uid then
    raise exception 'Activity not found';
  end if;

  if a.status in ('live', 'completed', 'expired', 'cancelled') then
    raise exception 'Activity can no longer be edited';
  end if;

  if p_title is not null and length(trim(p_title)) < 3 then
    raise exception 'Title must be at least 3 characters';
  end if;

  if p_duration_minutes is not null
     and (p_duration_minutes < 1 or p_duration_minutes > 720) then
    raise exception 'Invalid duration';
  end if;

  if p_capacity is not null
     and (p_capacity < 2 or p_capacity > 100) then
    raise exception 'Invalid capacity';
  end if;

  if p_start_time is not null
     and p_start_time <= now() then
    raise exception 'Start time must be in the future';
  end if;

  update public.activities
  set
    title = coalesce(left(trim(p_title), 120), title),
    description = coalesce(left(p_description, 2000), description),
    start_time = coalesce(p_start_time, start_time),
    duration_minutes = coalesce(p_duration_minutes, duration_minutes),
    capacity = coalesce(p_capacity, capacity),
    region = coalesce(left(p_region, 100), region),
    mode = coalesce(left(p_mode, 100), mode),
    updated_at = now()
  where id = p_activity_id;

  return true;
end;
$$;

create or replace function public.confirm_participation(
  p_activity_id uuid,
  p_participant_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  target_user uuid;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;

  target_user := coalesce(p_participant_id, uid);

  if target_user <> uid then
    raise exception 'Not authorized';
  end if;

  if not exists (
    select 1
    from public.participants
    where activity_id = p_activity_id
      and user_id = target_user
  ) then
    raise exception 'Participation not found';
  end if;

  update public.participants
  set
    status = 'confirmed',
    confirmed_at = coalesce(confirmed_at, now())
  where activity_id = p_activity_id
    and user_id = target_user;

  return true;
end;
$$;

commit;

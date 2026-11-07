-- AIRDROP PUBGM launch-readiness: fixed reward values and safe withdrawal reservations.
-- Cash withdrawals are disabled by default; enabling them requires separate explicit approval after testing.
-- Rates are application policy, not live FX conversion:
-- 1 reward credit = NGN 10 or USD 0.01. No withdrawal fee is currently configured.
-- This migration is intentionally stored in the feature branch and is NOT applied to production.

create table if not exists public.withdrawal_settings (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into public.withdrawal_settings(id, enabled) values(true, false)
on conflict (id) do nothing;
alter table public.withdrawal_settings enable row level security;

alter table public.withdrawal_requests
  add column if not exists credits_reserved boolean not null default false;

-- Keep one open request per user, including approved requests awaiting manual payout.
create unique index if not exists withdrawal_requests_one_open_per_user
  on public.withdrawal_requests (user_id)
  where status in ('pending'::public.withdrawal_status,
                   'under_review'::public.withdrawal_status,
                   'approved'::public.withdrawal_status);

-- Replace the legacy disabled 3-argument overload with the controlled NGN default.
create or replace function public.request_withdrawal(
  p_requested_credits integer,
  p_bank_name text,
  p_account_number text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.request_withdrawal(
    p_requested_credits,
    10::numeric,
    0,
    p_bank_name,
    p_account_number,
    'NGN'::text
  );
end;
$$;

-- Retain the existing client signature for compatibility, but do not trust its rate/fee.
create or replace function public.request_withdrawal(
  p_requested_credits integer,
  p_exchange_rate numeric,
  p_fee_credits integer,
  p_bank_name text,
  p_account_number text,
  p_currency text default 'NGN'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  rid uuid;
  balance integer;
  currency_code text := upper(trim(coalesce(p_currency, 'NGN')));
  expected_rate numeric;
  withdrawals_enabled boolean := false;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select enabled into withdrawals_enabled from public.withdrawal_settings where id = true;
  if not coalesce(withdrawals_enabled, false) then
    raise exception 'Cash withdrawals are not enabled yet. Your request was not created.';
  end if;

  if currency_code not in ('NGN', 'USD') then
    raise exception 'Unsupported withdrawal currency';
  end if;
  expected_rate := case currency_code when 'NGN' then 10::numeric when 'USD' then 0.01::numeric end;

  if p_requested_credits is null or p_requested_credits < 1
     or p_exchange_rate is distinct from expected_rate
     or coalesce(p_fee_credits, -1) <> 0
     or length(trim(coalesce(p_bank_name, ''))) < 2
     or length(trim(coalesce(p_account_number, ''))) < 4 then
    raise exception 'Invalid withdrawal details or payout rate';
  end if;

  -- Lock the balance row before checking and reserving credits.
  select reward_credits into balance
  from public.profiles where id = uid for update;
  if balance is null then raise exception 'Profile not found'; end if;

  if exists (
    select 1 from public.withdrawal_requests
    where user_id = uid
      and status in ('pending'::public.withdrawal_status,
                     'under_review'::public.withdrawal_status,
                     'approved'::public.withdrawal_status)
  ) then
    raise exception 'Existing withdrawal request is still open';
  end if;

  if balance < p_requested_credits then raise exception 'Insufficient reward credits'; end if;

  update public.profiles
    set reward_credits = reward_credits - p_requested_credits
    where id = uid;

  insert into public.withdrawal_requests(
    user_id, requested_credits, exchange_rate, fee_credits,
    payout_amount, currency, bank_name, account_number, status, credits_reserved
  ) values (
    uid, p_requested_credits, expected_rate, 0,
    round(p_requested_credits * expected_rate, 2), currency_code,
    trim(p_bank_name), trim(p_account_number), 'pending', true
  ) returning id into rid;

  insert into public.reward_credit_transactions(user_id, amount, reason)
  values(uid, -p_requested_credits, 'withdrawal_reserved');

  insert into public.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(uid, 'withdrawal_requested', 'withdrawal', rid,
         jsonb_build_object('credits', p_requested_credits, 'currency', currency_code));

  return rid;
end;
$$;

-- Admins can advance a request; rejection refunds credits that this workflow reserved.
-- "paid" records a manually verified bank transfer; it does not send money automatically.
create or replace function public.admin_update_withdrawal(
  p_withdrawal_id uuid,
  p_status public.withdrawal_status,
  p_note text default null
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  w public.withdrawal_requests;
begin
  if uid is null or not exists (
    select 1 from public.admin_roles
    where user_id = uid and role in ('admin', 'super_admin')
  ) then
    raise exception 'Admin access denied';
  end if;

  if p_status not in ('under_review'::public.withdrawal_status,
                      'approved'::public.withdrawal_status,
                      'rejected'::public.withdrawal_status,
                      'paid'::public.withdrawal_status) then
    raise exception 'Unsupported withdrawal status transition';
  end if;

  select * into w from public.withdrawal_requests
  where id = p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal request not found'; end if;

  if w.status in ('paid'::public.withdrawal_status,
                  'rejected'::public.withdrawal_status,
                  'cancelled'::public.withdrawal_status) then
    raise exception 'This withdrawal request is already closed';
  end if;

  if p_status = 'under_review' and w.status <> 'pending' then
    raise exception 'Only pending requests can enter review';
  elsif p_status = 'approved' and w.status not in ('pending', 'under_review') then
    raise exception 'Only pending or reviewed requests can be approved';
  elsif p_status = 'paid' and w.status <> 'approved' then
    raise exception 'Only approved requests can be marked paid';
  elsif p_status = 'rejected' and w.status not in ('pending', 'under_review', 'approved') then
    raise exception 'Request cannot be rejected from its current state';
  end if;

  if p_status = 'rejected' and w.credits_reserved then
    update public.profiles
      set reward_credits = reward_credits + w.requested_credits
      where id = w.user_id;
    insert into public.reward_credit_transactions(user_id, amount, reason)
      values(w.user_id, w.requested_credits, 'withdrawal_refund');
  end if;

  update public.withdrawal_requests
    set status = p_status,
        reviewer_note = case when nullif(trim(coalesce(p_note, '')), '') is null
                             then reviewer_note else trim(p_note) end,
        reviewed_at = case when p_status in ('under_review', 'approved', 'rejected')
                           then now() else reviewed_at end,
        paid_at = case when p_status = 'paid' then now() else paid_at end,
        credits_reserved = case when p_status in ('rejected', 'paid') then false else credits_reserved end
    where id = p_withdrawal_id;

  insert into public.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(uid, 'withdrawal_status_changed', 'withdrawal', p_withdrawal_id,
         jsonb_build_object('from', w.status, 'to', p_status, 'note', nullif(trim(coalesce(p_note, '')), '')));

  return true;
end;
$$;

revoke all on function public.admin_update_withdrawal(uuid, public.withdrawal_status, text) from public, anon;
grant execute on function public.admin_update_withdrawal(uuid, public.withdrawal_status, text) to authenticated;

-- Only authenticated users may create requests through the validated RPC.
revoke all on function public.request_withdrawal(integer, numeric, integer, text, text, text) from public, anon;
grant execute on function public.request_withdrawal(integer, numeric, integer, text, text, text) to authenticated;
revoke all on function public.request_withdrawal(integer, text, text) from public, anon;
grant execute on function public.request_withdrawal(integer, text, text) to authenticated;

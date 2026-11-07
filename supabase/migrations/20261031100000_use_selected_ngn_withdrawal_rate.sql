-- AIRDROP PUBGM: prepare the selected NGN withdrawal conversion rate.
-- IMPORTANT: this migration is committed to airdroppubgm-development only.
-- It has NOT been applied to the live Supabase project.
-- Existing withdrawal rows, payout amounts, and transaction history are untouched.
--
-- The six-argument RPC is the single source of truth. It validates the expected
-- NGN rate server-side, reserves earned reward credits atomically, and records
-- the payout amount at request time. Existing historical requests retain their
-- stored payout_amount and exchange_rate.

create or replace function public.request_withdrawal(
  p_requested_credits integer,
  p_exchange_rate numeric,
  p_fee_credits integer,
  p_bank_name text,
  p_account_number text,
  p_currency text default 'NGN'::text
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  uid uuid := auth.uid();
  rid uuid;
  balance integer;
  currency_code text := upper(trim(coalesce(p_currency, 'NGN')));
  expected_rate numeric;
  withdrawals_enabled boolean := false;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select enabled into withdrawals_enabled
  from public.withdrawal_settings where id = true;

  if not coalesce(withdrawals_enabled, false) then
    raise exception 'Cash withdrawals are not enabled yet. Your request was not created.';
  end if;

  if currency_code not in ('NGN', 'USD') then
    raise exception 'Unsupported withdrawal currency';
  end if;

  expected_rate := case currency_code
    when 'NGN' then 1300::numeric
    when 'USD' then 0.01::numeric
  end;

  if p_requested_credits is null or p_requested_credits < 1
     or p_exchange_rate is distinct from expected_rate
     or coalesce(p_fee_credits, -1) <> 0
     or length(trim(coalesce(p_bank_name, ''))) < 2
     or length(trim(coalesce(p_account_number, ''))) < 4 then
    raise exception 'Invalid withdrawal details or payout rate';
  end if;

  select reward_credits into balance
  from public.profiles where id = uid for update;

  if balance is null then raise exception 'Profile not found'; end if;

  if exists (
    select 1 from public.withdrawal_requests
    where user_id = uid
      and status in (
        'pending'::public.withdrawal_status,
        'under_review'::public.withdrawal_status,
        'approved'::public.withdrawal_status
      )
  ) then
    raise exception 'Existing withdrawal request is still open';
  end if;

  if balance < p_requested_credits then
    raise exception 'Insufficient reward credits';
  end if;

  update public.profiles
  set reward_credits = reward_credits - p_requested_credits
  where id = uid;

  insert into public.withdrawal_requests(
    user_id, requested_credits, exchange_rate, fee_credits, payout_amount,
    currency, bank_name, account_number, status, credits_reserved
  ) values (
    uid, p_requested_credits, expected_rate, 0,
    round(p_requested_credits * expected_rate, 2), currency_code,
    trim(p_bank_name), trim(p_account_number), 'pending', true
  ) returning id into rid;

  insert into public.reward_credit_transactions(user_id, amount, reason)
  values(uid, -p_requested_credits, 'withdrawal_reserved');

  insert into public.audit_logs(actor_user_id, action, entity_type, entity_id, metadata)
  values(uid, 'withdrawal_requested', 'withdrawal', rid,
         jsonb_build_object('credits', p_requested_credits, 'currency', currency_code,
                            'exchange_rate', expected_rate));

  return rid;
end;
$function$;

-- Keep the current app-facing overloads compatible, but route them through
-- the selected server-side rate. No caller can choose an arbitrary rate.
create or replace function public.request_withdrawal(
  p_requested_credits integer,
  p_bank_name text,
  p_account_number text
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  return public.request_withdrawal(
    p_requested_credits, 1300::numeric, 0,
    p_bank_name, p_account_number, 'NGN'::text
  );
end;
$function$;

create or replace function public.request_withdrawal(
  p_requested_credits integer,
  p_bank_name text,
  p_account_name text,
  p_account_number text
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if length(trim(coalesce(p_account_name, ''))) < 2
     or length(trim(coalesce(p_account_name, ''))) > 100 then
    raise exception 'Enter the account holder name (2–100 characters).';
  end if;
  if trim(coalesce(p_bank_name, '')) = ''
     or trim(coalesce(p_account_number, '')) !~ '^[0-9]{8,20}$' then
    raise exception 'Choose a bank and enter an account number containing 8–20 digits.';
  end if;

  v_id := public.request_withdrawal(
    p_requested_credits, 1300::numeric, 0,
    trim(p_bank_name), trim(p_account_number), 'NGN'::text
  );

  update public.withdrawal_requests
  set account_name = trim(p_account_name)
  where id = v_id and user_id = auth.uid();

  return v_id;
end;
$function$;

revoke execute on function public.request_withdrawal(integer, text, text) from public, anon;
revoke execute on function public.request_withdrawal(integer, text, text, text) from public, anon;
revoke execute on function public.request_withdrawal(integer, numeric, integer, text, text, text) from public, anon;
grant execute on function public.request_withdrawal(integer, text, text) to authenticated, service_role;
grant execute on function public.request_withdrawal(integer, text, text, text) to authenticated, service_role;
grant execute on function public.request_withdrawal(integer, numeric, integer, text, text, text) to authenticated, service_role;

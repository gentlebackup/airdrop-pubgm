-- AIRDROP PUBGM — explicit disabled-state responses for cash withdrawals
-- The wallet UI gets a safe, understandable response while payout controls are off.

begin;

create or replace function public.request_withdrawal(
 p_requested_credits integer,p_bank_name text,p_account_name text,p_account_number text
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare enabled_value boolean;
begin
 select enabled into enabled_value from public.withdrawal_settings where id=true;
 if not coalesce(enabled_value,false) then
  raise exception 'Cash withdrawals are not enabled yet. Your reward credits remain in your wallet.';
 end if;
 raise exception 'Withdrawal processing has not been activated. Your reward credits remain in your wallet.';
end $$;

create or replace function public.admin_update_withdrawal(
 p_withdrawal_id uuid,p_status text,p_note text default null
) returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform public._airdrop_require_admin(false);
 raise exception 'Cash withdrawal processing is disabled. No payout status was changed.';
end $$;

revoke all on function public.request_withdrawal(integer,text,text,text) from public,anon;
revoke all on function public.admin_update_withdrawal(uuid,text,text) from public,anon;
grant execute on function public.request_withdrawal(integer,text,text,text) to authenticated;
grant execute on function public.admin_update_withdrawal(uuid,text,text) to authenticated;

commit;

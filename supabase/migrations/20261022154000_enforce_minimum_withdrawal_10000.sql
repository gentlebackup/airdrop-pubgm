-- Enforce the minimum cash withdrawal amount at the database layer.
-- 1 credit = NGN 10, so 1,000 credits = NGN 10,000.
create or replace function public.enforce_minimum_withdrawal_amount()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.requested_credits < 1000 then
    raise exception 'Minimum withdrawal is 1000 credits (NGN 10000)';
  end if;
  return new;
end;
$$;

drop trigger if exists withdrawal_requests_minimum_amount on public.withdrawal_requests;
create trigger withdrawal_requests_minimum_amount
before insert on public.withdrawal_requests
for each row
execute function public.enforce_minimum_withdrawal_amount();

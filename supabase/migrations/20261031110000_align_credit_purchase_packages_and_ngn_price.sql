-- Align credit purchase requests with the current public package list and NGN price.
-- Development branch only. Do not apply to production without explicit approval.
-- Existing purchase requests and historical amount_ngn values are not changed.

create or replace function public.create_credit_purchase_request(
  p_package_credits integer,
  p_transfer_reference text default null::text
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_id uuid;
  v_enabled boolean;
begin
  if auth.uid() is null then
    raise exception 'Sign in to request a credit purchase.';
  end if;

  select enabled into v_enabled
  from public.credit_purchase_settings
  where id = true;

  if coalesce(v_enabled, false) = false then
    raise exception 'Credit purchases are not open yet. Please try again later.';
  end if;

  if p_package_credits not in (
    1,2,3,4,5,6,7,8,9,10,20,30,50,60,80,100,150,200,250,300
  ) then
    raise exception 'Choose one of the available credit packages.';
  end if;

  insert into public.credit_purchase_requests(
    user_id, package_credits, amount_ngn, transfer_reference
  )
  values (
    auth.uid(), p_package_credits, p_package_credits * 1300,
    nullif(trim(p_transfer_reference), '')
  )
  returning id into v_id;

  return v_id;
end;
$function$;

revoke execute on function public.create_credit_purchase_request(integer, text) from public, anon;
grant execute on function public.create_credit_purchase_request(integer, text) to authenticated, service_role;

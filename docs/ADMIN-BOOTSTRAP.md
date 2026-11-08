# AIRDROP PUBGM — first administrator setup

The admin dashboard is protected by rows in `public.admin_roles`. No administrator is created automatically.

1. Create your normal player account through AIRDROP PUBGM after the app is connected to the new Supabase project.
2. In Supabase, open **Authentication → Users** and copy that account's UUID.
3. Open the project's **SQL Editor** and run the statement below after replacing the UUID with your own account UUID:

```sql
insert into public.admin_roles(user_id, role)
values ('PASTE-YOUR-ACCOUNT-UUID-HERE', 'owner')
on conflict (user_id, role) do nothing;
```

4. Sign out and sign back in, then open the app's admin route.

Important:
- Only grant the `owner` role to an account you control.
- Never put a service-role key in the browser, app code, GitHub, or Vercel client-side environment variables.
- Do not grant admin roles to other users from the client.
- Credit purchase approvals are manual and disabled until the payment workflow is deliberately enabled.
- Cash withdrawals remain disabled; the current withdrawal RPC explicitly refuses to process payouts.

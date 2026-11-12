-- BAJAJ security hardening: remove anonymous access from private shop data.
-- All application data is intended to be accessed after Supabase sign-in.

-- Convert legacy PUBLIC policies to authenticated-only policies.
do $$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and roles = array['public']::name[]
  loop
    execute format(
      'alter policy %I on %I.%I to authenticated',
      p.policyname, p.schemaname, p.tablename
    );
  end loop;
end $$;

-- The app has no anonymous public-data workflow.
revoke all privileges on all tables in schema public from anon;
revoke usage on schema public from anon;

-- Remove default anonymous grants from future objects created by postgres.
alter default privileges for role postgres in schema public
  revoke all on tables from anon;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon;

-- Trigger functions are internal-only; application RPCs are authenticated-only.
do $$
declare f record;
begin
  for f in
    select p.oid,
           p.prorettype = 'trigger'::regtype as is_trigger
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and p.proname in (
        'adjust_stock',
        'approve_credit_sale',
        'attach_sale_to_open_shift',
        'can_manage_shop_members',
        'capture_activity_event',
        'close_cashier_shift',
        'create_sale',
        'guard_shop_membership_changes',
        'handle_new_user',
        'has_shop_role',
        'is_platform_admin',
        'is_shop_member',
        'open_cashier_shift',
        'receive_purchase',
        'record_product_opening_stock',
        'record_repayment',
        'reject_credit_sale',
        'update_shop_settings',
        'void_sale'
      )
  loop
    if f.is_trigger then
      execute format(
        'revoke all on function %s from public, anon, authenticated, service_role',
        f.oid::regprocedure
      );
    else
      execute format(
        'revoke all on function %s from public, anon',
        f.oid::regprocedure
      );
      execute format(
        'grant execute on function %s to authenticated, service_role',
        f.oid::regprocedure
      );
    end if;
  end loop;
end $$;

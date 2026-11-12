-- Enforce the active subscription's product and staff limits at the database boundary.
create or replace function public.enforce_subscription_usage_limits()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  subscription_status text;
  trial_end timestamptz;
  product_limit integer;
  user_limit integer;
  current_usage bigint;
begin
  select ss.status, ss.trial_ends_at, sp.max_products, sp.max_users
    into subscription_status, trial_end, product_limit, user_limit
  from public.shop_subscriptions ss
  join public.subscription_plans sp on sp.id = ss.plan_id
  where ss.shop_id = new.shop_id
    and sp.is_active = true;

  if not found then
    raise exception 'This shop has no active subscription plan. Contact the BAJAJ platform administrator.';
  end if;

  if subscription_status not in ('trialing','active')
     or (subscription_status = 'trialing' and trial_end <= now()) then
    raise exception 'This shop subscription is not active. Contact the BAJAJ platform administrator.';
  end if;

  if tg_table_name = 'products' then
    select count(*) into current_usage from public.products where shop_id = new.shop_id;
    if current_usage >= product_limit then
      raise exception 'Product limit reached for this subscription plan (% products). Upgrade the plan to add more products.', product_limit;
    end if;
  elsif tg_table_name = 'shop_members' then
    select count(*) into current_usage from public.shop_members where shop_id = new.shop_id;
    if current_usage >= user_limit then
      raise exception 'User limit reached for this subscription plan (% users). Upgrade the plan to add more users.', user_limit;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_shop_product_subscription_limit on public.products;
create trigger enforce_shop_product_subscription_limit
before insert on public.products
for each row execute function public.enforce_subscription_usage_limits();

drop trigger if exists enforce_shop_user_subscription_limit on public.shop_members;
create trigger enforce_shop_user_subscription_limit
before insert on public.shop_members
for each row execute function public.enforce_subscription_usage_limits();

revoke all on function public.enforce_subscription_usage_limits() from public, anon, authenticated;

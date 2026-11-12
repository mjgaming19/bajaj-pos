-- Batch 15: SaaS subscription plans, trials, shop status and platform billing controls
create table if not exists public.subscription_plans (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  code text not null unique,
  description text,
  monthly_price numeric(12,2) not null default 0 check (monthly_price >= 0),
  yearly_price numeric(12,2) not null default 0 check (yearly_price >= 0),
  max_users integer not null default 5 check (max_users > 0),
  max_products integer not null default 500 check (max_products > 0),
  max_shops integer not null default 1 check (max_shops > 0),
  features jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.shop_subscriptions (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null unique references public.shops(id) on delete cascade,
  plan_id uuid not null references public.subscription_plans(id),
  status text not null default 'trialing' check (status in ('trialing','active','past_due','cancelled','suspended')),
  billing_cycle text not null default 'monthly' check (billing_cycle in ('monthly','yearly')),
  trial_starts_at timestamptz not null default now(),
  trial_ends_at timestamptz not null default (now() + interval '14 days'),
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  admin_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.subscription_events (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  subscription_id uuid references public.shop_subscriptions(id) on delete set null,
  event_type text not null,
  details jsonb not null default '{}'::jsonb,
  actor_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists shop_subscriptions_status_idx on public.shop_subscriptions(status);
create index if not exists subscription_events_shop_created_idx on public.subscription_events(shop_id, created_at desc);

alter table public.subscription_plans enable row level security;
alter table public.shop_subscriptions enable row level security;
alter table public.subscription_events enable row level security;

drop policy if exists "Authenticated users can view active subscription plans" on public.subscription_plans;
create policy "Authenticated users can view active subscription plans"
on public.subscription_plans for select to authenticated
using (is_active = true or public.is_platform_admin());

drop policy if exists "Platform admins manage subscription plans" on public.subscription_plans;
create policy "Platform admins manage subscription plans"
on public.subscription_plans for all to authenticated
using (public.is_platform_admin())
with check (public.is_platform_admin());

drop policy if exists "Shop members view their subscription" on public.shop_subscriptions;
create policy "Shop members view their subscription"
on public.shop_subscriptions for select to authenticated
using (public.is_platform_admin() or public.has_shop_role(shop_id, array['sub_admin','pos_user']));

drop policy if exists "Platform admins manage shop subscriptions" on public.shop_subscriptions;
create policy "Platform admins manage shop subscriptions"
on public.shop_subscriptions for all to authenticated
using (public.is_platform_admin())
with check (public.is_platform_admin());

drop policy if exists "Platform admins view subscription events" on public.subscription_events;
create policy "Platform admins view subscription events"
on public.subscription_events for select to authenticated
using (public.is_platform_admin());

drop policy if exists "Platform admins add subscription events" on public.subscription_events;
create policy "Platform admins add subscription events"
on public.subscription_events for insert to authenticated
with check (public.is_platform_admin());

grant select, insert, update, delete on public.subscription_plans to authenticated;
grant select, insert, update, delete on public.shop_subscriptions to authenticated;
grant select, insert on public.subscription_events to authenticated;

insert into public.subscription_plans
  (name, code, description, monthly_price, yearly_price, max_users, max_products, max_shops, features, sort_order)
values
  ('Starter', 'starter', 'For a single shop getting started with digital inventory and POS.', 0, 0, 5, 500, 1,
   '{"pos":true,"inventory":true,"reports":true,"customers":true,"suppliers":true,"expenses":false,"advanced_analytics":false}'::jsonb, 1),
  ('Professional', 'professional', 'For growing shops that need the complete management toolkit.', 0, 0, 20, 10000, 5,
   '{"pos":true,"inventory":true,"reports":true,"customers":true,"suppliers":true,"expenses":true,"advanced_analytics":true}'::jsonb, 2)
on conflict (code) do nothing;

insert into public.shop_subscriptions (shop_id, plan_id, status, trial_starts_at, trial_ends_at)
select s.id, p.id, 'trialing', now(), now() + interval '14 days'
from public.shops s
cross join lateral (select id from public.subscription_plans where code='starter' limit 1) p
on conflict (shop_id) do nothing;

create or replace function public.create_shop_trial_subscription()
returns trigger language plpgsql security definer set search_path = public
as $$
declare starter_plan_id uuid;
begin
  select id into starter_plan_id from public.subscription_plans where code='starter' and is_active=true limit 1;
  if starter_plan_id is not null then
    insert into public.shop_subscriptions(shop_id, plan_id, status, trial_starts_at, trial_ends_at)
    values(new.id, starter_plan_id, 'trialing', now(), now() + interval '14 days')
    on conflict (shop_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists shops_create_trial_subscription on public.shops;
create trigger shops_create_trial_subscription after insert on public.shops
for each row execute function public.create_shop_trial_subscription();

create or replace function public.log_subscription_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.subscription_events(shop_id, subscription_id, event_type, details, actor_id)
    values(new.shop_id, new.id, 'subscription_created',
      jsonb_build_object('plan_id',new.plan_id,'status',new.status,'trial_ends_at',new.trial_ends_at), auth.uid());
    return new;
  end if;
  if row(new.plan_id,new.status,new.billing_cycle,new.trial_ends_at,new.current_period_end,new.cancel_at_period_end)
     is distinct from
     row(old.plan_id,old.status,old.billing_cycle,old.trial_ends_at,old.current_period_end,old.cancel_at_period_end) then
    insert into public.subscription_events(shop_id, subscription_id, event_type, details, actor_id)
    values(new.shop_id, new.id, 'subscription_updated',
      jsonb_build_object('old_status',old.status,'new_status',new.status,'old_plan_id',old.plan_id,'new_plan_id',new.plan_id,
                         'trial_ends_at',new.trial_ends_at,'current_period_end',new.current_period_end), auth.uid());
  end if;
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists shop_subscriptions_log_change on public.shop_subscriptions;
create trigger shop_subscriptions_log_change before insert or update on public.shop_subscriptions
for each row execute function public.log_subscription_change();

create or replace function public.touch_subscription_plan_updated_at()
returns trigger language plpgsql set search_path=public as $$
begin new.updated_at=now(); return new; end;
$$;
drop trigger if exists subscription_plans_touch_updated_at on public.subscription_plans;
create trigger subscription_plans_touch_updated_at before update on public.subscription_plans
for each row execute function public.touch_subscription_plan_updated_at();

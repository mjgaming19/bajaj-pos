-- BAJAJ Batch 5C: automatic activity history and shop-member role guard
-- Safe to run once in the Supabase SQL Editor.

create table if not exists public.activity_events (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists activity_events_shop_created_idx
  on public.activity_events (shop_id, created_at desc);

alter table public.activity_events enable row level security;

drop policy if exists "Platform admins and shop managers read activity" on public.activity_events;
create policy "Platform admins and shop managers read activity"
on public.activity_events for select to authenticated
using (
  exists (select 1 from public.platform_admins pa where pa.user_id = auth.uid())
  or exists (
    select 1 from public.shop_members sm
    where sm.shop_id = activity_events.shop_id
      and sm.user_id = auth.uid()
      and sm.role = 'sub_admin'
  )
);

create or replace function public.capture_activity_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_data jsonb;
  event_shop_id uuid;
  event_id text;
begin
  if tg_op = 'DELETE' then
    row_data := to_jsonb(old);
  else
    row_data := to_jsonb(new);
  end if;

  event_shop_id := nullif(row_data->>'shop_id', '')::uuid;
  event_id := row_data->>'id';

  if event_shop_id is not null then
    insert into public.activity_events
      (shop_id, actor_id, action, entity_type, entity_id, details)
    values (
      event_shop_id,
      auth.uid(),
      lower(tg_op),
      tg_table_name,
      event_id,
      jsonb_build_object(
        'record', row_data,
        'changed_at', now()
      )
    );
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

do $$
declare
  table_name text;
  target_tables text[] := array[
    'products',
    'sales',
    'customers',
    'suppliers',
    'purchase_orders',
    'payments',
    'stock_movements',
    'inventory_movements'
  ];
begin
  foreach table_name in array target_tables loop
    if to_regclass('public.' || table_name) is not null then
      execute format('drop trigger if exists bajaj_capture_activity on public.%I', table_name);
      execute format(
        'create trigger bajaj_capture_activity after insert or update or delete on public.%I for each row execute function public.capture_activity_event()',
        table_name
      );
    end if;
  end loop;
end;
$$;

-- Sub-admins may manage POS-user memberships in their own shop only.
-- They cannot create/promote/remove another sub-admin or alter another shop.
create or replace function public.guard_shop_membership_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_is_platform_admin boolean;
  actor_is_shop_manager boolean;
begin
  select exists (
    select 1 from public.platform_admins
    where user_id = auth.uid()
  ) into actor_is_platform_admin;

  if actor_is_platform_admin then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    select exists (
      select 1 from public.shop_members
      where shop_id = old.shop_id
        and user_id = auth.uid()
        and role = 'sub_admin'
    ) into actor_is_shop_manager;

    if not actor_is_shop_manager or old.role <> 'pos_user' then
      raise exception 'Only a platform admin can remove a sub-admin or manage memberships outside their shop.';
    end if;
    return old;
  end if;

  select exists (
    select 1 from public.shop_members
    where shop_id = new.shop_id
      and user_id = auth.uid()
      and role = 'sub_admin'
  ) into actor_is_shop_manager;

  if not actor_is_shop_manager
     or new.role <> 'pos_user'
     or (tg_op = 'UPDATE' and (
       old.role <> 'pos_user'
       or new.shop_id <> old.shop_id
       or new.user_id <> old.user_id
     )) then
    raise exception 'Sub-admins can only assign or update POS-user memberships within their own shop.';
  end if;

  return new;
end;
$$;

drop trigger if exists bajaj_guard_shop_membership_changes on public.shop_members;
create trigger bajaj_guard_shop_membership_changes
before insert or update or delete on public.shop_members
for each row execute function public.guard_shop_membership_changes();

-- Reusable SECURITY DEFINER check avoids recursive shop_members RLS lookups.
create or replace function public.can_manage_shop_members(p_shop_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    exists (select 1 from public.platform_admins pa where pa.user_id = auth.uid())
    or exists (
      select 1 from public.shop_members sm
      where sm.shop_id = p_shop_id
        and sm.user_id = auth.uid()
        and sm.role = 'sub_admin'
    );
$$;

drop policy if exists "Platform admins and sub-admins add shop members" on public.shop_members;
create policy "Platform admins and sub-admins add shop members"
on public.shop_members for insert to authenticated
with check (public.can_manage_shop_members(shop_id));

drop policy if exists "Platform admins and sub-admins update shop members" on public.shop_members;
create policy "Platform admins and sub-admins update shop members"
on public.shop_members for update to authenticated
using (public.can_manage_shop_members(shop_id))
with check (public.can_manage_shop_members(shop_id));

drop policy if exists "Platform admins and sub-admins remove shop members" on public.shop_members;
create policy "Platform admins and sub-admins remove shop members"
on public.shop_members for delete to authenticated
using (public.can_manage_shop_members(shop_id));

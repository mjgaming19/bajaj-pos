-- BAJAJ Batch 13: in-app notifications and operational reminders

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  type text not null check (type in ('low_stock')),
  severity text not null default 'warning' check (severity in ('info','warning','critical')),
  title text not null,
  message text not null,
  entity_type text,
  entity_id uuid,
  dedupe_key text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  read_at timestamptz,
  resolved_at timestamptz
);

create unique index if not exists notifications_active_dedupe_idx
  on public.notifications(shop_id,dedupe_key)
  where resolved_at is null;
create index if not exists notifications_shop_created_idx
  on public.notifications(shop_id,created_at desc);
create index if not exists notifications_shop_unread_idx
  on public.notifications(shop_id,created_at desc)
  where read_at is null and resolved_at is null;

alter table public.notifications enable row level security;
revoke all on public.notifications from anon,authenticated;
grant select on public.notifications to authenticated;
drop policy if exists "Shop members read notifications" on public.notifications;
create policy "Shop members read notifications"
  on public.notifications for select to authenticated
  using (public.is_shop_member(shop_id));

create or replace function public.sync_low_stock_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_threshold integer := coalesce(new.low_stock_threshold,5);
  v_key text := 'low-stock:' || new.id::text;
begin
  if coalesce(new.quantity,0) <= v_threshold then
    insert into public.notifications(
      shop_id,type,severity,title,message,entity_type,entity_id,dedupe_key
    ) values (
      new.shop_id,'low_stock','warning','Low stock: ' || new.product_name,
      new.product_name || ' (' || coalesce(new.product_code,'no code') || ') has ' ||
        coalesce(new.quantity,0)::text || ' unit(s) remaining. Reorder threshold: ' ||
        v_threshold::text || '.',
      'product',new.id,v_key
    )
    on conflict (shop_id,dedupe_key) where resolved_at is null
    do update set
      title=excluded.title,
      message=excluded.message,
      updated_at=now();
  else
    update public.notifications
      set resolved_at=now(),updated_at=now()
      where shop_id=new.shop_id
        and dedupe_key=v_key
        and resolved_at is null;
  end if;
  return new;
end;
$function$;

revoke all on function public.sync_low_stock_notification() from public,anon,authenticated;
drop trigger if exists trg_sync_low_stock_notification on public.products;
create trigger trg_sync_low_stock_notification
  after insert or update of quantity,low_stock_threshold
  on public.products
  for each row execute function public.sync_low_stock_notification();

-- Seed alerts for products that were already below their reorder threshold.
insert into public.notifications(
  shop_id,type,severity,title,message,entity_type,entity_id,dedupe_key
)
select p.shop_id,'low_stock','warning','Low stock: ' || p.product_name,
  p.product_name || ' (' || coalesce(p.product_code,'no code') || ') has ' ||
  coalesce(p.quantity,0)::text || ' unit(s) remaining. Reorder threshold: ' ||
  coalesce(p.low_stock_threshold,5)::text || '.',
  'product',p.id,'low-stock:' || p.id::text
from public.products p
where coalesce(p.quantity,0) <= coalesce(p.low_stock_threshold,5)
on conflict (shop_id,dedupe_key) where resolved_at is null
do update set title=excluded.title,message=excluded.message,updated_at=now();

create or replace function public.mark_notification_read(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_shop_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select shop_id into v_shop_id
    from public.notifications
    where id=p_notification_id;
  if not found then raise exception 'Notification not found'; end if;
  if not public.is_shop_member(v_shop_id) then
    raise exception 'You do not have access to this shop';
  end if;
  update public.notifications
    set read_at=coalesce(read_at,now()),updated_at=now()
    where id=p_notification_id and shop_id=v_shop_id;
end;
$function$;

create or replace function public.mark_all_notifications_read(p_shop_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.is_shop_member(p_shop_id) then
    raise exception 'You do not have access to this shop';
  end if;
  update public.notifications
    set read_at=now(),updated_at=now()
    where shop_id=p_shop_id and read_at is null and resolved_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

revoke all on function public.mark_notification_read(uuid) from public,anon;
revoke all on function public.mark_all_notifications_read(uuid) from public,anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;
grant execute on function public.mark_all_notifications_read(uuid) to authenticated;

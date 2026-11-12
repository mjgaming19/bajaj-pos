-- BAJAJ Batch 7A: cashier shifts and cash reconciliation
create table if not exists public.cashier_shifts (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  cashier_id uuid not null references auth.users(id),
  opened_at timestamptz not null default now(),
  opening_cash numeric(12,2) not null default 0 check (opening_cash >= 0),
  closed_at timestamptz,
  closing_cash numeric(12,2),
  expected_cash numeric(12,2),
  cash_difference numeric(12,2),
  status text not null default 'open' check (status in ('open','closed')),
  closing_note text,
  created_at timestamptz not null default now(),
  constraint cashier_shifts_close_values check (
    (status = 'open' and closed_at is null and closing_cash is null)
    or (status = 'closed' and closed_at is not null and closing_cash is not null and expected_cash is not null)
  )
);
create unique index if not exists cashier_shifts_one_open_per_user
  on public.cashier_shifts(shop_id,cashier_id) where status='open';
create index if not exists cashier_shifts_shop_opened_idx
  on public.cashier_shifts(shop_id,opened_at desc);

alter table public.sales add column if not exists shift_id uuid references public.cashier_shifts(id) on delete set null;
create index if not exists sales_shift_id_idx on public.sales(shift_id);

alter table public.cashier_shifts enable row level security;
grant select on public.cashier_shifts to authenticated;
drop policy if exists "cashier shifts read own or managers" on public.cashier_shifts;
create policy "cashier shifts read own or managers" on public.cashier_shifts
for select to authenticated using (
  cashier_id = auth.uid()
  or exists (select 1 from public.platform_admins pa where pa.user_id=auth.uid())
  or exists (select 1 from public.shop_members sm where sm.shop_id=cashier_shifts.shop_id and sm.user_id=auth.uid() and sm.role='sub_admin')
);
revoke insert, update, delete on public.cashier_shifts from anon, authenticated;

create or replace function public.open_cashier_shift(p_shop_id uuid,p_opening_cash numeric)
returns public.cashier_shifts
language plpgsql security definer set search_path=public
as $$
declare result public.cashier_shifts;
begin
  if auth.uid() is null then raise exception 'Authentication required.'; end if;
  if p_opening_cash is null or p_opening_cash < 0 then raise exception 'Opening cash must be zero or more.'; end if;
  if not (
    exists(select 1 from public.platform_admins pa where pa.user_id=auth.uid())
    or exists(select 1 from public.shop_members sm where sm.shop_id=p_shop_id and sm.user_id=auth.uid())
  ) then raise exception 'You are not a member of this shop.'; end if;
  if exists(select 1 from public.cashier_shifts cs where cs.shop_id=p_shop_id and cs.cashier_id=auth.uid() and cs.status='open') then
    raise exception 'You already have an open shift for this shop.';
  end if;
  insert into public.cashier_shifts(shop_id,cashier_id,opening_cash)
  values(p_shop_id,auth.uid(),p_opening_cash)
  returning * into result;
  return result;
end;
$$;

create or replace function public.close_cashier_shift(p_shift_id uuid,p_closing_cash numeric,p_closing_note text default null)
returns public.cashier_shifts
language plpgsql security definer set search_path=public
as $$
declare
  sh public.cashier_shifts;
  cash_sales numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Authentication required.'; end if;
  if p_closing_cash is null or p_closing_cash < 0 then raise exception 'Closing cash must be zero or more.'; end if;
  select * into sh from public.cashier_shifts where id=p_shift_id for update;
  if sh.id is null then raise exception 'Shift not found.'; end if;
  if sh.status <> 'open' then raise exception 'This shift is already closed.'; end if;
  if sh.cashier_id <> auth.uid()
     and not exists(select 1 from public.platform_admins pa where pa.user_id=auth.uid())
     and not exists(select 1 from public.shop_members sm where sm.shop_id=sh.shop_id and sm.user_id=auth.uid() and sm.role='sub_admin') then
    raise exception 'You cannot close this shift.';
  end if;
  select coalesce(sum(s.total),0) into cash_sales
  from public.sales s
  where s.shift_id=sh.id and s.status='completed' and s.payment_method='cash';
  update public.cashier_shifts
  set status='closed',closed_at=now(),closing_cash=p_closing_cash,
      expected_cash=opening_cash+cash_sales,
      cash_difference=p_closing_cash-(opening_cash+cash_sales),
      closing_note=nullif(trim(p_closing_note),'')
  where id=sh.id returning * into sh;
  return sh;
end;
$$;

create or replace function public.attach_sale_to_open_shift()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if new.shift_id is null and new.shop_id is not null then
    select cs.id into new.shift_id
    from public.cashier_shifts cs
    where cs.shop_id=new.shop_id and cs.cashier_id=auth.uid() and cs.status='open'
    order by cs.opened_at desc limit 1;
  end if;
  return new;
end;
$$;
drop trigger if exists sales_attach_open_shift on public.sales;
create trigger sales_attach_open_shift
before insert on public.sales
for each row execute function public.attach_sale_to_open_shift();

revoke all on function public.open_cashier_shift(uuid,numeric) from public;
revoke all on function public.close_cashier_shift(uuid,numeric,text) from public;
grant execute on function public.open_cashier_shift(uuid,numeric) to authenticated;
grant execute on function public.close_cashier_shift(uuid,numeric,text) to authenticated;

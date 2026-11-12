-- BAJAJ Batch 14: shop expenses and net-profit reporting

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  category text not null,
  description text not null,
  amount numeric(12,2) not null check (amount > 0),
  expense_date date not null default current_date,
  payment_method text not null default 'cash'
    check (payment_method in ('cash','card','bank','other')),
  reference text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint expenses_category_not_blank check (length(trim(category)) > 0),
  constraint expenses_description_not_blank check (length(trim(description)) > 0)
);

create index if not exists expenses_shop_date_idx
  on public.expenses(shop_id,expense_date desc);
create index if not exists expenses_shop_category_idx
  on public.expenses(shop_id,category);

alter table public.expenses enable row level security;
revoke all on public.expenses from anon,authenticated;
grant select,insert,update,delete on public.expenses to authenticated;

drop policy if exists "Shop admins read expenses" on public.expenses;
create policy "Shop admins read expenses"
  on public.expenses for select to authenticated
  using (public.has_shop_role(shop_id,array['sub_admin']));
drop policy if exists "Shop admins create expenses" on public.expenses;
create policy "Shop admins create expenses"
  on public.expenses for insert to authenticated
  with check (public.has_shop_role(shop_id,array['sub_admin']) and (created_by is null or created_by=auth.uid()));
drop policy if exists "Shop admins update expenses" on public.expenses;
create policy "Shop admins update expenses"
  on public.expenses for update to authenticated
  using (public.has_shop_role(shop_id,array['sub_admin']))
  with check (public.has_shop_role(shop_id,array['sub_admin']));
drop policy if exists "Shop admins delete expenses" on public.expenses;
create policy "Shop admins delete expenses"
  on public.expenses for delete to authenticated
  using (public.has_shop_role(shop_id,array['sub_admin']));

create or replace function public.log_shop_expense_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_expense public.expenses%rowtype;
  v_action text;
begin
  if tg_op='DELETE' then
    v_expense:=old;
    v_action:='expense_deleted';
  elsif tg_op='UPDATE' then
    v_expense:=new;
    v_action:='expense_updated';
  else
    v_expense:=new;
    v_action:='expense_created';
  end if;

  insert into public.audit_logs(shop_id,user_id,action,details)
  values(
    v_expense.shop_id,coalesce(auth.uid(),v_expense.created_by),v_action,
    jsonb_build_object(
      'expense_id',v_expense.id,
      'category',v_expense.category,
      'description',v_expense.description,
      'amount',v_expense.amount,
      'expense_date',v_expense.expense_date,
      'payment_method',v_expense.payment_method
    )
  );

  if tg_op='DELETE' then return old; end if;
  return new;
end;
$function$;

revoke all on function public.log_shop_expense_change() from public,anon,authenticated;
drop trigger if exists trg_log_shop_expense_change on public.expenses;
create trigger trg_log_shop_expense_change
  after insert or update or delete on public.expenses
  for each row execute function public.log_shop_expense_change();

create or replace function public.touch_expense_updated_at()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  new.updated_at:=now();
  return new;
end;
$function$;
revoke all on function public.touch_expense_updated_at() from public,anon,authenticated;
drop trigger if exists trg_touch_expense_updated_at on public.expenses;
create trigger trg_touch_expense_updated_at
  before update on public.expenses
  for each row execute function public.touch_expense_updated_at();

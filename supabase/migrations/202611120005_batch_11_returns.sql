-- Batch 11A: product returns and refunds
alter table public.sales add column if not exists returned_amount numeric(12,2) not null default 0 check (returned_amount >= 0);
create table if not exists public.sale_returns (
 id uuid primary key default gen_random_uuid(), shop_id uuid not null references public.shops(id) on delete restrict,
 sale_id uuid not null references public.sales(id) on delete restrict, return_no text not null unique,
 refund_method text not null check (refund_method in ('cash','card','credit_adjustment')),
 refund_amount numeric(12,2) not null check (refund_amount > 0), reason text not null,
 created_by uuid references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.sale_return_items (
 id uuid primary key default gen_random_uuid(), return_id uuid not null references public.sale_returns(id) on delete restrict,
 sale_item_id uuid not null references public.sale_items(id) on delete restrict,
 product_id uuid not null references public.products(id) on delete restrict, product_name text not null,
 product_code text, quantity integer not null check (quantity > 0),
 unit_refund_amount numeric(12,2) not null check (unit_refund_amount >= 0), restocked boolean not null default true
);
create index if not exists sale_returns_shop_date_idx on public.sale_returns(shop_id,created_at desc);
create index if not exists sale_returns_sale_idx on public.sale_returns(sale_id);
create index if not exists sale_return_items_sale_item_idx on public.sale_return_items(sale_item_id);
alter table public.sale_returns enable row level security;
alter table public.sale_return_items enable row level security;
drop policy if exists "Shop members read sale returns" on public.sale_returns;
create policy "Shop members read sale returns" on public.sale_returns for select to authenticated using (public.is_shop_member(shop_id));
drop policy if exists "Shop members read sale return items" on public.sale_return_items;
create policy "Shop members read sale return items" on public.sale_return_items for select to authenticated using (
 exists (select 1 from public.sale_returns r where r.id=sale_return_items.return_id and public.is_shop_member(r.shop_id))
);
grant select on public.sale_returns,public.sale_return_items to authenticated;
revoke all on public.sale_returns,public.sale_return_items from anon;
CREATE OR REPLACE FUNCTION public.process_sale_return(p_sale_id uuid, p_items jsonb, p_reason text, p_refund_method text, p_refund_confirmed boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_sale public.sales%rowtype;
  v_item record;
  v_sale_item public.sale_items%rowtype;
  v_product public.products%rowtype;
  v_return_id uuid;
  v_return_no text;
  v_refund numeric(12,2) := 0;
  v_unit_refund numeric(12,2);
  v_already_returned integer;
  v_paid numeric(12,2);
  v_remaining numeric(12,2);
  v_new_returned numeric(12,2);
  v_payment_status text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A return reason is required.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Select at least one item to return.';
  end if;
  if p_refund_method not in ('cash','card','credit_adjustment') then
    raise exception 'Invalid refund method.';
  end if;

  select * into v_sale
  from public.sales
  where id = p_sale_id
  for update;
  if not found then raise exception 'Sale not found.'; end if;
  if not public.has_shop_role(v_sale.shop_id, array['sub_admin']) then
    raise exception 'Only a platform admin or shop sub-admin can approve returns.';
  end if;
  if v_sale.status <> 'completed' then
    raise exception 'Only completed sales can be returned.';
  end if;

  if (select count(*) from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean))
     <> (select count(distinct sale_item_id) from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean)) then
    raise exception 'Duplicate sale items were submitted.';
  end if;

  if p_refund_method = 'credit_adjustment' then
    if v_sale.payment_method <> 'credit' then
      raise exception 'Credit adjustments are only available for credit sales.';
    end if;
  else
    if v_sale.payment_method <> p_refund_method then
      raise exception 'Refund method must match the original cash or card payment.';
    end if;
    if coalesce(p_refund_confirmed,false) is not true then
      raise exception 'Confirm that the customer has actually received the refund.';
    end if;
  end if;

  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean)
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'Return quantities must be positive.';
    end if;
    select * into v_sale_item
    from public.sale_items
    where id = v_item.sale_item_id and sale_id = p_sale_id
    for update;
    if not found then raise exception 'A selected item does not belong to this sale.'; end if;

    select coalesce(sum(ri.quantity),0)::integer into v_already_returned
    from public.sale_return_items ri
    join public.sale_returns r on r.id = ri.return_id
    where ri.sale_item_id = v_sale_item.id;

    if v_item.quantity > v_sale_item.quantity - v_already_returned then
      raise exception 'Return quantity exceeds the remaining quantity for %.', v_sale_item.product_name;
    end if;

    if v_sale.subtotal > 0 then
      v_unit_refund := round(
        (v_sale_item.line_total
          - (v_sale.discount * (v_sale_item.line_total / v_sale.subtotal)))
        / v_sale_item.quantity, 2
      );
    else
      v_unit_refund := round(v_sale_item.unit_price,2);
    end if;
    v_refund := v_refund + (v_unit_refund * v_item.quantity);
  end loop;

  if v_refund <= 0 then raise exception 'The calculated refund must be greater than zero.'; end if;

  if p_refund_method = 'credit_adjustment' then
    select coalesce(sum(amount),0) into v_paid
    from public.payments where sale_id = p_sale_id;
    v_remaining := greatest(v_sale.total - coalesce(v_sale.returned_amount,0) - v_paid,0);
    if v_refund > v_remaining then
      raise exception 'This return exceeds the unpaid credit balance. Outstanding balance: %.', v_remaining;
    end if;
  end if;

  v_return_no := 'RET-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  insert into public.sale_returns(
    shop_id,sale_id,return_no,refund_method,refund_amount,reason,created_by
  ) values (
    v_sale.shop_id,p_sale_id,v_return_no,p_refund_method,v_refund,trim(p_reason),auth.uid()
  ) returning id into v_return_id;

  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean)
  loop
    select * into v_sale_item from public.sale_items where id=v_item.sale_item_id;
    if v_sale.subtotal > 0 then
      v_unit_refund := round(
        (v_sale_item.line_total
          - (v_sale.discount * (v_sale_item.line_total / v_sale.subtotal)))
        / v_sale_item.quantity, 2
      );
    else
      v_unit_refund := round(v_sale_item.unit_price,2);
    end if;

    insert into public.sale_return_items(
      return_id,sale_item_id,product_id,product_name,product_code,
      quantity,unit_refund_amount,restocked
    ) values (
      v_return_id,v_sale_item.id,v_sale_item.product_id,v_sale_item.product_name,
      v_sale_item.product_code,v_item.quantity,v_unit_refund,coalesce(v_item.restock,true)
    );

    if coalesce(v_item.restock,true) then
      update public.products
      set quantity=quantity+v_item.quantity,updated_at=now()
      where id=v_sale_item.product_id and shop_id=v_sale.shop_id
      returning * into v_product;
      if not found then raise exception 'Returned product is missing from this shop.'; end if;

      insert into public.inventory_movements(
        shop_id,product_id,movement_type,quantity_change,unit_cost,reference_id,notes,created_by
      ) values (
        v_sale.shop_id,v_sale_item.product_id,'customer_return',v_item.quantity,
        v_sale_item.unit_cost,v_return_id,'Customer return '||v_return_no,auth.uid()
      );
      insert into public.stock_movements(
        shop_id,product_id,movement_type,quantity_change,reference,notes,created_by
      ) values (
        v_sale.shop_id,v_sale_item.product_id,'return',v_item.quantity,v_return_no,
        'Customer return: '||trim(p_reason),auth.uid()
      );
    end if;
  end loop;

  v_new_returned := coalesce(v_sale.returned_amount,0)+v_refund;
  update public.sales
  set returned_amount=v_new_returned,
      payment_status=case
        when payment_method='credit' and
          (select coalesce(sum(amount),0) from public.payments where sale_id=p_sale_id)
            >= total-v_new_returned then 'paid'
        when payment_method='credit' and
          (select coalesce(sum(amount),0) from public.payments where sale_id=p_sale_id)>0 then 'partial'
        when payment_method='credit' then 'unpaid'
        else payment_status
      end
  where id=p_sale_id;

  insert into public.audit_logs(shop_id,user_id,action,details)
  values(v_sale.shop_id,auth.uid(),'sale_return_processed',jsonb_build_object(
    'sale_id',p_sale_id,'return_id',v_return_id,'return_no',v_return_no,
    'refund_amount',v_refund,'refund_method',p_refund_method,'reason',trim(p_reason)
  ));

  return jsonb_build_object(
    'return_id',v_return_id,'return_no',v_return_no,
    'sale_id',p_sale_id,'refund_amount',v_refund,'refund_method',p_refund_method
  );
end;
$function$

revoke all on function public.process_sale_return(uuid,jsonb,text,text,boolean) from public,anon;
grant execute on function public.process_sale_return(uuid,jsonb,text,text,boolean) to authenticated;
CREATE OR REPLACE FUNCTION public.record_repayment(p_sale_id uuid, p_amount numeric, p_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_sale public.sales%rowtype;
  v_paid numeric(12,2);
  v_remaining numeric(12,2);
  v_status text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_sale from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if not public.has_shop_role(v_sale.shop_id,array['sub_admin']) then
    raise exception 'Only a shop admin or platform admin can record repayments';
  end if;
  if v_sale.status <> 'completed' or v_sale.payment_method <> 'credit' then
    raise exception 'This is not an approved credit sale';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter a valid repayment amount'; end if;
  if p_method not in ('cash','card','other') then raise exception 'Invalid repayment method'; end if;

  select coalesce(sum(amount),0) into v_paid from public.payments where sale_id=p_sale_id;
  v_remaining := greatest(v_sale.total-coalesce(v_sale.returned_amount,0)-v_paid,0);
  if p_amount > v_remaining then raise exception 'Repayment exceeds the outstanding balance'; end if;

  insert into public.payments(shop_id,sale_id,amount,method,received_by)
  values(v_sale.shop_id,p_sale_id,p_amount,p_method,auth.uid());

  v_paid := v_paid+p_amount;
  if v_paid >= v_sale.total-coalesce(v_sale.returned_amount,0) then
    v_status := 'paid';
  elsif v_paid > 0 then v_status := 'partial';
  else v_status := 'unpaid'; end if;

  update public.sales set payment_status=v_status where id=p_sale_id;
  insert into public.audit_logs(shop_id,user_id,action,details)
  values(v_sale.shop_id,auth.uid(),'credit_repayment',jsonb_build_object(
    'sale_id',p_sale_id,'amount',p_amount,'payment_status',v_status
  ));
  return jsonb_build_object(
    'sale_id',p_sale_id,'amount_paid',v_paid,
    'remaining',greatest(v_sale.total-coalesce(v_sale.returned_amount,0)-v_paid,0),
    'payment_status',v_status
  );
end;
$function$

revoke all on function public.record_repayment(uuid,numeric,text) from public,anon;
grant execute on function public.record_repayment(uuid,numeric,text) to authenticated;
CREATE OR REPLACE FUNCTION public.prevent_void_after_return()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.status='voided' and old.status<>'voided'
     and coalesce(old.returned_amount,0)>0 then
    raise exception 'A sale with processed returns cannot be cancelled. Process any remaining items as a return.';
  end if;
  return new;
end;
$function$

drop trigger if exists prevent_void_after_return_trigger on public.sales;
create trigger prevent_void_after_return_trigger before update of status on public.sales for each row execute function public.prevent_void_after_return();
revoke all on function public.prevent_void_after_return() from public,anon,authenticated;


-- Reconcile cash refunds against the original cashier shift.
CREATE OR REPLACE FUNCTION public.process_sale_return(p_sale_id uuid, p_items jsonb, p_reason text, p_refund_method text, p_refund_confirmed boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_sale public.sales%rowtype;
  v_item record;
  v_sale_item public.sale_items%rowtype;
  v_product public.products%rowtype;
  v_return_id uuid;
  v_return_no text;
  v_refund numeric(12,2) := 0;
  v_unit_refund numeric(12,2);
  v_already_returned integer;
  v_paid numeric(12,2);
  v_remaining numeric(12,2);
  v_new_returned numeric(12,2);
  v_payment_status text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A return reason is required.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Select at least one item to return.';
  end if;
  if p_refund_method not in ('cash','card','credit_adjustment') then
    raise exception 'Invalid refund method.';
  end if;

  select * into v_sale
  from public.sales
  where id = p_sale_id
  for update;
  if not found then raise exception 'Sale not found.'; end if;
  if not public.has_shop_role(v_sale.shop_id, array['sub_admin']) then
    raise exception 'Only a platform admin or shop sub-admin can approve returns.';
  end if;
  if v_sale.status <> 'completed' then
    raise exception 'Only completed sales can be returned.';
  end if;

  if (select count(*) from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean))
     <> (select count(distinct sale_item_id) from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean)) then
    raise exception 'Duplicate sale items were submitted.';
  end if;

  if p_refund_method = 'credit_adjustment' then
    if v_sale.payment_method <> 'credit' then
      raise exception 'Credit adjustments are only available for credit sales.';
    end if;
  else
    if v_sale.payment_method <> p_refund_method then
      raise exception 'Refund method must match the original cash or card payment.';
    end if;
    if coalesce(p_refund_confirmed,false) is not true then
      raise exception 'Confirm that the customer has actually received the refund.';
    end if;
  end if;

  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean)
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'Return quantities must be positive.';
    end if;
    select * into v_sale_item
    from public.sale_items
    where id = v_item.sale_item_id and sale_id = p_sale_id
    for update;
    if not found then raise exception 'A selected item does not belong to this sale.'; end if;

    select coalesce(sum(ri.quantity),0)::integer into v_already_returned
    from public.sale_return_items ri
    join public.sale_returns r on r.id = ri.return_id
    where ri.sale_item_id = v_sale_item.id;

    if v_item.quantity > v_sale_item.quantity - v_already_returned then
      raise exception 'Return quantity exceeds the remaining quantity for %.', v_sale_item.product_name;
    end if;

    if v_sale.subtotal > 0 then
      v_unit_refund := round(
        (v_sale_item.line_total
          - (v_sale.discount * (v_sale_item.line_total / v_sale.subtotal)))
        / v_sale_item.quantity, 2
      );
    else
      v_unit_refund := round(v_sale_item.unit_price,2);
    end if;
    v_refund := v_refund + (v_unit_refund * v_item.quantity);
  end loop;

  if v_refund <= 0 then raise exception 'The calculated refund must be greater than zero.'; end if;

  if p_refund_method = 'credit_adjustment' then
    select coalesce(sum(amount),0) into v_paid
    from public.payments where sale_id = p_sale_id;
    v_remaining := greatest(v_sale.total - coalesce(v_sale.returned_amount,0) - v_paid,0);
    if v_refund > v_remaining then
      raise exception 'This return exceeds the unpaid credit balance. Outstanding balance: %.', v_remaining;
    end if;
  end if;

  v_return_no := 'RET-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  insert into public.sale_returns(
    shop_id,sale_id,return_no,refund_method,refund_amount,reason,created_by
  ) values (
    v_sale.shop_id,p_sale_id,v_return_no,p_refund_method,v_refund,trim(p_reason),auth.uid()
  ) returning id into v_return_id;

  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean)
  loop
    select * into v_sale_item from public.sale_items where id=v_item.sale_item_id;
    if v_sale.subtotal > 0 then
      v_unit_refund := round(
        (v_sale_item.line_total
          - (v_sale.discount * (v_sale_item.line_total / v_sale.subtotal)))
        / v_sale_item.quantity, 2
      );
    else
      v_unit_refund := round(v_sale_item.unit_price,2);
    end if;

    insert into public.sale_return_items(
      return_id,sale_item_id,product_id,product_name,product_code,
      quantity,unit_refund_amount,restocked
    ) values (
      v_return_id,v_sale_item.id,v_sale_item.product_id,v_sale_item.product_name,
      v_sale_item.product_code,v_item.quantity,v_unit_refund,coalesce(v_item.restock,true)
    );

    if coalesce(v_item.restock,true) then
      update public.products
      set quantity=quantity+v_item.quantity,updated_at=now()
      where id=v_sale_item.product_id and shop_id=v_sale.shop_id
      returning * into v_product;
      if not found then raise exception 'Returned product is missing from this shop.'; end if;

      insert into public.inventory_movements(
        shop_id,product_id,movement_type,quantity_change,unit_cost,reference_id,notes,created_by
      ) values (
        v_sale.shop_id,v_sale_item.product_id,'customer_return',v_item.quantity,
        v_sale_item.unit_cost,v_return_id,'Customer return '||v_return_no,auth.uid()
      );
      insert into public.stock_movements(
        shop_id,product_id,movement_type,quantity_change,reference,notes,created_by
      ) values (
        v_sale.shop_id,v_sale_item.product_id,'return',v_item.quantity,v_return_no,
        'Customer return: '||trim(p_reason),auth.uid()
      );
    end if;
  end loop;

  v_new_returned := coalesce(v_sale.returned_amount,0)+v_refund;
  update public.sales
  set returned_amount=v_new_returned,
      payment_status=case
        when payment_method='credit' and
          (select coalesce(sum(amount),0) from public.payments where sale_id=p_sale_id)
            >= total-v_new_returned then 'paid'
        when payment_method='credit' and
          (select coalesce(sum(amount),0) from public.payments where sale_id=p_sale_id)>0 then 'partial'
        when payment_method='credit' then 'unpaid'
        else payment_status
      end
  where id=p_sale_id;

  if p_refund_method='cash' and v_sale.shift_id is not null then
    update public.cashier_shifts
    set expected_cash=coalesce(expected_cash,opening_cash)-v_refund,
        cash_difference=closing_cash-(coalesce(expected_cash,opening_cash)-v_refund)
    where id=v_sale.shift_id and status='closed';
  end if;

  insert into public.audit_logs(shop_id,user_id,action,details)
  values(v_sale.shop_id,auth.uid(),'sale_return_processed',jsonb_build_object(
    'sale_id',p_sale_id,'return_id',v_return_id,'return_no',v_return_no,
    'refund_amount',v_refund,'refund_method',p_refund_method,'reason',trim(p_reason)
  ));

  return jsonb_build_object(
    'return_id',v_return_id,'return_no',v_return_no,
    'sale_id',p_sale_id,'refund_amount',v_refund,'refund_method',p_refund_method
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.close_cashier_shift(p_shift_id uuid, p_closing_cash numeric, p_closing_note text DEFAULT NULL::text)
 RETURNS public.cashier_shifts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sh public.cashier_shifts; cash_sales numeric(12,2);
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
  select coalesce(sum(s.total),0) - coalesce((
    select sum(r.refund_amount) from public.sale_returns r
    join public.sales rs on rs.id=r.sale_id
    where rs.shift_id=sh.id and r.refund_method='cash'
  ),0) into cash_sales
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
$function$;
revoke all on function public.close_cashier_shift(uuid,numeric,text) from public,anon;
grant execute on function public.close_cashier_shift(uuid,numeric,text) to authenticated;


-- Batch 11B: linked exchanges with replacement sales.
alter table public.sale_returns add column if not exists replacement_sale_id uuid references public.sales(id) on delete restrict;
alter table public.sale_returns drop constraint if exists sale_returns_refund_method_check;
alter table public.sale_returns add constraint sale_returns_refund_method_check check(refund_method in ('cash','card','credit_adjustment','exchange_credit'));
CREATE OR REPLACE FUNCTION public.process_sale_return(p_sale_id uuid, p_items jsonb, p_reason text, p_refund_method text, p_refund_confirmed boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_sale public.sales%rowtype;
  v_item record;
  v_sale_item public.sale_items%rowtype;
  v_product public.products%rowtype;
  v_return_id uuid;
  v_return_no text;
  v_refund numeric(12,2) := 0;
  v_unit_refund numeric(12,2);
  v_already_returned integer;
  v_paid numeric(12,2);
  v_remaining numeric(12,2);
  v_new_returned numeric(12,2);
  v_payment_status text;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A return reason is required.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Select at least one item to return.';
  end if;
  if p_refund_method is null or p_refund_method not in ('cash','card','credit_adjustment','exchange_credit') then
    raise exception 'Invalid refund method.';
  end if;

  select * into v_sale
  from public.sales
  where id = p_sale_id
  for update;
  if not found then raise exception 'Sale not found.'; end if;
  if not public.has_shop_role(v_sale.shop_id, array['sub_admin']) then
    raise exception 'Only a platform admin or shop sub-admin can approve returns.';
  end if;
  if v_sale.status <> 'completed' then
    raise exception 'Only completed sales can be returned.';
  end if;

  if (select count(*) from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean))
     <> (select count(distinct sale_item_id) from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean)) then
    raise exception 'Duplicate sale items were submitted.';
  end if;

  if p_refund_method = 'credit_adjustment' then
    if v_sale.payment_method <> 'credit' then
      raise exception 'Credit adjustments are only available for credit sales.';
    end if;
  elsif p_refund_method = 'exchange_credit' then
    if v_sale.payment_method not in ('cash','card') then
      raise exception 'Exchanges are currently supported for cash and card sales.';
    end if;
  else
    if v_sale.payment_method <> p_refund_method then
      raise exception 'Refund method must match the original cash or card payment.';
    end if;
    if coalesce(p_refund_confirmed,false) is not true then
      raise exception 'Confirm that the customer has actually received the refund.';
    end if;
  end if;

  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean)
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'Return quantities must be positive.';
    end if;
    select * into v_sale_item
    from public.sale_items
    where id = v_item.sale_item_id and sale_id = p_sale_id
    for update;
    if not found then raise exception 'A selected item does not belong to this sale.'; end if;

    select coalesce(sum(ri.quantity),0)::integer into v_already_returned
    from public.sale_return_items ri
    join public.sale_returns r on r.id = ri.return_id
    where ri.sale_item_id = v_sale_item.id;

    if v_item.quantity > v_sale_item.quantity - v_already_returned then
      raise exception 'Return quantity exceeds the remaining quantity for %.', v_sale_item.product_name;
    end if;

    if v_sale.subtotal > 0 then
      v_unit_refund := round(
        (v_sale_item.line_total
          - (v_sale.discount * (v_sale_item.line_total / v_sale.subtotal)))
        / v_sale_item.quantity, 2
      );
    else
      v_unit_refund := round(v_sale_item.unit_price,2);
    end if;
    v_refund := v_refund + (v_unit_refund * v_item.quantity);
  end loop;

  if v_refund <= 0 then raise exception 'The calculated refund must be greater than zero.'; end if;

  if p_refund_method = 'credit_adjustment' then
    select coalesce(sum(amount),0) into v_paid
    from public.payments where sale_id = p_sale_id;
    v_remaining := greatest(v_sale.total - coalesce(v_sale.returned_amount,0) - v_paid,0);
    if v_refund > v_remaining then
      raise exception 'This return exceeds the unpaid credit balance. Outstanding balance: %.', v_remaining;
    end if;
  end if;

  v_return_no := 'RET-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  insert into public.sale_returns(
    shop_id,sale_id,return_no,refund_method,refund_amount,reason,created_by
  ) values (
    v_sale.shop_id,p_sale_id,v_return_no,p_refund_method,v_refund,trim(p_reason),auth.uid()
  ) returning id into v_return_id;

  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(sale_item_id uuid, quantity integer, restock boolean)
  loop
    select * into v_sale_item from public.sale_items where id=v_item.sale_item_id;
    if v_sale.subtotal > 0 then
      v_unit_refund := round(
        (v_sale_item.line_total
          - (v_sale.discount * (v_sale_item.line_total / v_sale.subtotal)))
        / v_sale_item.quantity, 2
      );
    else
      v_unit_refund := round(v_sale_item.unit_price,2);
    end if;

    insert into public.sale_return_items(
      return_id,sale_item_id,product_id,product_name,product_code,
      quantity,unit_refund_amount,restocked
    ) values (
      v_return_id,v_sale_item.id,v_sale_item.product_id,v_sale_item.product_name,
      v_sale_item.product_code,v_item.quantity,v_unit_refund,coalesce(v_item.restock,true)
    );

    if coalesce(v_item.restock,true) then
      update public.products
      set quantity=quantity+v_item.quantity,updated_at=now()
      where id=v_sale_item.product_id and shop_id=v_sale.shop_id
      returning * into v_product;
      if not found then raise exception 'Returned product is missing from this shop.'; end if;

      insert into public.inventory_movements(
        shop_id,product_id,movement_type,quantity_change,unit_cost,reference_id,notes,created_by
      ) values (
        v_sale.shop_id,v_sale_item.product_id,'customer_return',v_item.quantity,
        v_sale_item.unit_cost,v_return_id,'Customer return '||v_return_no,auth.uid()
      );
      insert into public.stock_movements(
        shop_id,product_id,movement_type,quantity_change,reference,notes,created_by
      ) values (
        v_sale.shop_id,v_sale_item.product_id,'return',v_item.quantity,v_return_no,
        'Customer return: '||trim(p_reason),auth.uid()
      );
    end if;
  end loop;

  v_new_returned := coalesce(v_sale.returned_amount,0)+v_refund;
  update public.sales
  set returned_amount=v_new_returned,
      payment_status=case
        when payment_method='credit' and
          (select coalesce(sum(amount),0) from public.payments where sale_id=p_sale_id)
            >= total-v_new_returned then 'paid'
        when payment_method='credit' and
          (select coalesce(sum(amount),0) from public.payments where sale_id=p_sale_id)>0 then 'partial'
        when payment_method='credit' then 'unpaid'
        else payment_status
      end
  where id=p_sale_id;

  if p_refund_method='cash' and v_sale.shift_id is not null then
    update public.cashier_shifts
    set expected_cash=coalesce(expected_cash,opening_cash)-v_refund,
        cash_difference=closing_cash-(coalesce(expected_cash,opening_cash)-v_refund)
    where id=v_sale.shift_id and status='closed';
  end if;

  insert into public.audit_logs(shop_id,user_id,action,details)
  values(v_sale.shop_id,auth.uid(),'sale_return_processed',jsonb_build_object(
    'sale_id',p_sale_id,'return_id',v_return_id,'return_no',v_return_no,
    'refund_amount',v_refund,'refund_method',p_refund_method,'reason',trim(p_reason)
  ));

  return jsonb_build_object(
    'return_id',v_return_id,'return_no',v_return_no,
    'sale_id',p_sale_id,'refund_amount',v_refund,'refund_method',p_refund_method
  );
end;
$function$
;
revoke all on function public.process_sale_return(uuid,jsonb,text,text,boolean) from public,anon;
grant execute on function public.process_sale_return(uuid,jsonb,text,text,boolean) to authenticated;
CREATE OR REPLACE FUNCTION public.process_sale_exchange(p_sale_id uuid, p_return_items jsonb, p_replacement_items jsonb, p_reason text, p_payment_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
 v_sale public.sales%rowtype;
 v_item record;
 v_product public.products%rowtype;
 v_return jsonb;
 v_return_id uuid;
 v_credit numeric(12,2);
 v_subtotal numeric(12,2):=0;
 v_due numeric(12,2);
 v_new_sale_id uuid;
 v_receipt text;
begin
 if auth.uid() is null then raise exception 'Authentication required.'; end if;
 if p_reason is null or length(trim(p_reason))=0 then raise exception 'An exchange reason is required.'; end if;
 if jsonb_typeof(p_replacement_items)<>'array' or jsonb_array_length(p_replacement_items)=0 then
   raise exception 'Select at least one replacement product.';
 end if;
 if p_payment_method not in ('cash','card') then raise exception 'Exchange balance must be paid by cash or card.'; end if;
 select * into v_sale from public.sales where id=p_sale_id for update;
 if not found then raise exception 'Original sale not found.'; end if;
 if v_sale.status<>'completed' or v_sale.payment_method not in ('cash','card') then
   raise exception 'Only completed cash or card sales can be exchanged.';
 end if;
 if not public.has_shop_role(v_sale.shop_id,array['sub_admin']) then
   raise exception 'Only a platform admin or shop sub-admin can process exchanges.';
 end if;
 if p_payment_method='cash' and not exists(
   select 1 from public.cashier_shifts where shop_id=v_sale.shop_id and cashier_id=auth.uid() and status='open'
 ) then
   raise exception 'Open a cashier shift before completing a cash exchange.';
 end if;

 for v_item in select * from jsonb_to_recordset(p_replacement_items) as x(product_id uuid,quantity integer)
 loop
   if v_item.quantity is null or v_item.quantity<=0 then raise exception 'Replacement quantities must be positive.'; end if;
   select * into v_product from public.products where id=v_item.product_id and shop_id=v_sale.shop_id for update;
   if not found then raise exception 'A replacement product is not available in this shop.'; end if;
   if v_product.quantity<v_item.quantity then raise exception 'Insufficient stock for replacement product %.',v_product.product_name; end if;
   v_subtotal:=v_subtotal+(v_product.selling_price*v_item.quantity);
 end loop;

 v_return:=public.process_sale_return(p_sale_id,p_return_items,p_reason,'exchange_credit',false);
 v_credit:=coalesce((v_return->>'refund_amount')::numeric,0);
 if v_credit>v_subtotal then raise exception 'Replacement value must be at least the returned item value. Replacement value: %, exchange credit: %.',v_subtotal,v_credit; end if;
 v_due:=v_subtotal-v_credit;
 v_receipt:='BAJ-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
 insert into public.sales(shop_id,receipt_no,customer_id,cashier_id,status,payment_status,payment_method,subtotal,discount,total,notes)
 values(v_sale.shop_id,v_receipt,v_sale.customer_id,auth.uid(),'completed','paid',p_payment_method,v_subtotal,v_credit,v_due,
   'Replacement sale for exchange against '||coalesce(v_sale.receipt_no,p_sale_id::text))
 returning id into v_new_sale_id;

 for v_item in select * from jsonb_to_recordset(p_replacement_items) as x(product_id uuid,quantity integer)
 loop
   select * into v_product from public.products where id=v_item.product_id and shop_id=v_sale.shop_id for update;
   update public.products set quantity=quantity-v_item.quantity,updated_at=now()
    where id=v_product.id and quantity>=v_item.quantity;
   if not found then raise exception 'Insufficient stock for replacement product %.',v_product.product_name; end if;
   insert into public.sale_items(sale_id,product_id,product_name,product_code,quantity,unit_price,unit_cost,line_total)
   values(v_new_sale_id,v_product.id,v_product.product_name,v_product.product_code,v_item.quantity,
     v_product.selling_price,v_product.cost_price,v_product.selling_price*v_item.quantity);
   insert into public.stock_movements(shop_id,product_id,movement_type,quantity_change,reference,notes,created_by)
   values(v_sale.shop_id,v_product.id,'sale',-v_item.quantity,v_receipt,'Replacement item for exchange',auth.uid());
 end loop;

 if v_due>0 then
   insert into public.payments(shop_id,sale_id,amount,method,received_by,notes)
   values(v_sale.shop_id,v_new_sale_id,v_due,p_payment_method,auth.uid(),'Exchange balance');
 end if;
 v_return_id:=(v_return->>'return_id')::uuid;
 update public.sale_returns set replacement_sale_id=v_new_sale_id where id=v_return_id;
 insert into public.audit_logs(shop_id,user_id,action,details)
 values(v_sale.shop_id,auth.uid(),'sale_exchange_processed',jsonb_build_object(
   'original_sale_id',p_sale_id,'replacement_sale_id',v_new_sale_id,'return_id',v_return_id,
   'exchange_credit',v_credit,'amount_paid',v_due
 ));
 return jsonb_build_object('return_id',v_return_id,'return_no',v_return->>'return_no',
   'replacement_sale_id',v_new_sale_id,'receipt_no',v_receipt,'exchange_credit',v_credit,'amount_paid',v_due);
end;
$function$
;
revoke all on function public.process_sale_exchange(uuid,jsonb,jsonb,text,text) from public,anon;
grant execute on function public.process_sale_exchange(uuid,jsonb,jsonb,text,text) to authenticated;


-- Permit exchanges to use returned stock when the returned part is marked resellable.
CREATE OR REPLACE FUNCTION public.process_sale_exchange(p_sale_id uuid, p_return_items jsonb, p_replacement_items jsonb, p_reason text, p_payment_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
 v_sale public.sales%rowtype;
 v_item record;
 v_product public.products%rowtype;
 v_return jsonb;
 v_return_id uuid;
 v_credit numeric(12,2);
 v_subtotal numeric(12,2):=0;
 v_due numeric(12,2);
 v_new_sale_id uuid;
 v_receipt text;
begin
 if auth.uid() is null then raise exception 'Authentication required.'; end if;
 if p_reason is null or length(trim(p_reason))=0 then raise exception 'An exchange reason is required.'; end if;
 if jsonb_typeof(p_replacement_items)<>'array' or jsonb_array_length(p_replacement_items)=0 then
   raise exception 'Select at least one replacement product.';
 end if;
 if p_payment_method not in ('cash','card') then raise exception 'Exchange balance must be paid by cash or card.'; end if;
 select * into v_sale from public.sales where id=p_sale_id for update;
 if not found then raise exception 'Original sale not found.'; end if;
 if v_sale.status<>'completed' or v_sale.payment_method not in ('cash','card') then
   raise exception 'Only completed cash or card sales can be exchanged.';
 end if;
 if not public.has_shop_role(v_sale.shop_id,array['sub_admin']) then
   raise exception 'Only a platform admin or shop sub-admin can process exchanges.';
 end if;
 if p_payment_method='cash' and not exists(
   select 1 from public.cashier_shifts where shop_id=v_sale.shop_id and cashier_id=auth.uid() and status='open'
 ) then
   raise exception 'Open a cashier shift before completing a cash exchange.';
 end if;

 for v_item in select * from jsonb_to_recordset(p_replacement_items) as x(product_id uuid,quantity integer)
 loop
   if v_item.quantity is null or v_item.quantity<=0 then raise exception 'Replacement quantities must be positive.'; end if;
   select * into v_product from public.products where id=v_item.product_id and shop_id=v_sale.shop_id for update;
   if not found then raise exception 'A replacement product is not available in this shop.'; end if;
   -- Stock is checked after returned sellable items have been restocked.
   v_subtotal:=v_subtotal+(v_product.selling_price*v_item.quantity);
 end loop;

 v_return:=public.process_sale_return(p_sale_id,p_return_items,p_reason,'exchange_credit',false);
 v_credit:=coalesce((v_return->>'refund_amount')::numeric,0);
 if v_credit>v_subtotal then raise exception 'Replacement value must be at least the returned item value. Replacement value: %, exchange credit: %.',v_subtotal,v_credit; end if;
 v_due:=v_subtotal-v_credit;
 v_receipt:='BAJ-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
 insert into public.sales(shop_id,receipt_no,customer_id,cashier_id,status,payment_status,payment_method,subtotal,discount,total,notes)
 values(v_sale.shop_id,v_receipt,v_sale.customer_id,auth.uid(),'completed','paid',p_payment_method,v_subtotal,v_credit,v_due,
   'Replacement sale for exchange against '||coalesce(v_sale.receipt_no,p_sale_id::text))
 returning id into v_new_sale_id;

 for v_item in select * from jsonb_to_recordset(p_replacement_items) as x(product_id uuid,quantity integer)
 loop
   select * into v_product from public.products where id=v_item.product_id and shop_id=v_sale.shop_id for update;
   update public.products set quantity=quantity-v_item.quantity,updated_at=now()
    where id=v_product.id and quantity>=v_item.quantity;
   if not found then raise exception 'Insufficient stock for replacement product %.',v_product.product_name; end if;
   insert into public.sale_items(sale_id,product_id,product_name,product_code,quantity,unit_price,unit_cost,line_total)
   values(v_new_sale_id,v_product.id,v_product.product_name,v_product.product_code,v_item.quantity,
     v_product.selling_price,v_product.cost_price,v_product.selling_price*v_item.quantity);
   insert into public.stock_movements(shop_id,product_id,movement_type,quantity_change,reference,notes,created_by)
   values(v_sale.shop_id,v_product.id,'sale',-v_item.quantity,v_receipt,'Replacement item for exchange',auth.uid());
 end loop;

 if v_due>0 then
   insert into public.payments(shop_id,sale_id,amount,method,received_by,notes)
   values(v_sale.shop_id,v_new_sale_id,v_due,p_payment_method,auth.uid(),'Exchange balance');
 end if;
 v_return_id:=(v_return->>'return_id')::uuid;
 update public.sale_returns set replacement_sale_id=v_new_sale_id where id=v_return_id;
 insert into public.audit_logs(shop_id,user_id,action,details)
 values(v_sale.shop_id,auth.uid(),'sale_exchange_processed',jsonb_build_object(
   'original_sale_id',p_sale_id,'replacement_sale_id',v_new_sale_id,'return_id',v_return_id,
   'exchange_credit',v_credit,'amount_paid',v_due
 ));
 return jsonb_build_object('return_id',v_return_id,'return_no',v_return->>'return_no',
   'replacement_sale_id',v_new_sale_id,'receipt_no',v_receipt,'exchange_credit',v_credit,'amount_paid',v_due);
end;
$function$
;
revoke all on function public.process_sale_exchange(uuid,jsonb,jsonb,text,text) from public,anon;
grant execute on function public.process_sale_exchange(uuid,jsonb,jsonb,text,text) to authenticated;


-- Cover the return ledger foreign keys with indexes.
create index if not exists sale_returns_created_by_idx on public.sale_returns(created_by);
create index if not exists sale_returns_replacement_sale_idx on public.sale_returns(replacement_sale_id);
create index if not exists sale_return_items_return_idx on public.sale_return_items(return_id);
create index if not exists sale_return_items_product_idx on public.sale_return_items(product_id);

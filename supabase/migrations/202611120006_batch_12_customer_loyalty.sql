-- BAJAJ Batch 12: customer profiles, purchase history and loyalty
alter table public.customers add column if not exists email text, add column if not exists notes text;

create table if not exists public.customer_loyalty_points (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops(id) on delete cascade,
 customer_id uuid not null references public.customers(id) on delete cascade,
 sale_id uuid references public.sales(id) on delete set null,
 entry_type text not null check (entry_type in ('earn','return_adjustment','redeem','redeem_return')),
 points integer not null check (points <> 0),
 note text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now()
);
create index if not exists customer_loyalty_points_customer_created_idx
 on public.customer_loyalty_points(shop_id,customer_id,created_at desc);
create index if not exists customer_loyalty_points_sale_idx
 on public.customer_loyalty_points(sale_id) where sale_id is not null;
alter table public.customer_loyalty_points enable row level security;
revoke all on public.customer_loyalty_points from anon,authenticated;
grant select on public.customer_loyalty_points to authenticated;
drop policy if exists "Shop members read customer loyalty points" on public.customer_loyalty_points;
create policy "Shop members read customer loyalty points"
 on public.customer_loyalty_points for select to authenticated
 using (public.has_shop_role(shop_id,array['sub_admin','pos_user']));

create or replace function public.sync_customer_loyalty_points()
returns trigger language plpgsql set search_path=public as $function$
declare
 v_target_earned integer:=0; v_current_earned integer:=0; v_delta integer:=0;
 v_redeemed integer:=0; v_target_reversed integer:=0; v_current_reversed integer:=0;
begin
 if new.customer_id is null then return new; end if;
 if new.status='completed' then
  v_target_earned:=floor(greatest(coalesce(new.total,0)-coalesce(new.returned_amount,0),0)/100)::integer;
 end if;
 select coalesce(sum(points),0)::integer into v_current_earned
 from public.customer_loyalty_points where sale_id=new.id and entry_type in ('earn','return_adjustment');
 v_delta:=v_target_earned-v_current_earned;
 if v_delta<>0 then
  insert into public.customer_loyalty_points(shop_id,customer_id,sale_id,entry_type,points,note,created_by)
  values(new.shop_id,new.customer_id,new.id,
   case when v_delta>0 and v_current_earned=0 then 'earn' else 'return_adjustment' end,
   v_delta,
   case when v_delta>0 then 'Loyalty points earned: 1 point per LKR 100 net spend'
   else 'Loyalty points adjusted after return or cancellation' end,coalesce(auth.uid(),new.cashier_id));
 end if;
 select coalesce(sum(-points),0)::integer into v_redeemed
 from public.customer_loyalty_points where sale_id=new.id and entry_type='redeem';
 if new.status='voided' then v_target_reversed:=v_redeemed;
 elsif new.status='completed' and coalesce(new.total,0)>0 then
  v_target_reversed:=floor(v_redeemed*least(greatest(coalesce(new.returned_amount,0)/new.total,0),1))::integer;
 end if;
 select coalesce(sum(points),0)::integer into v_current_reversed
 from public.customer_loyalty_points where sale_id=new.id and entry_type='redeem_return';
 v_delta:=v_target_reversed-v_current_reversed;
 if v_delta>0 then
  insert into public.customer_loyalty_points(shop_id,customer_id,sale_id,entry_type,points,note,created_by)
  values(new.shop_id,new.customer_id,new.id,'redeem_return',v_delta,
   'Proportional loyalty points restored after return or cancellation',coalesce(auth.uid(),new.cashier_id));
 end if;
 return new;
end;
$function$;
revoke all on function public.sync_customer_loyalty_points() from public,anon,authenticated;
drop trigger if exists trg_sync_customer_loyalty_points on public.sales;
create trigger trg_sync_customer_loyalty_points
 after insert or update of status,returned_amount,total,customer_id on public.sales
 for each row execute function public.sync_customer_loyalty_points();

CREATE OR REPLACE FUNCTION public.create_sale(p_shop_id uuid, p_customer_id uuid, p_payment_method text, p_items jsonb, p_discount numeric, p_loyalty_points integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item record;
  v_product public.products%rowtype;
  v_subtotal numeric(12,2) := 0;
  v_total numeric(12,2);
  v_sale_id uuid;
  v_receipt text;
  v_status text;
  v_payment_status text;
  v_loyalty_balance integer := 0;
  v_customer_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not public.has_shop_role(
    p_shop_id, array['sub_admin', 'pos_user']
  ) then
    raise exception 'You do not have access to this shop';
  end if;

  if p_payment_method not in ('cash', 'card', 'credit') then
    raise exception 'Invalid payment method';
  end if;

  if jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;

  if p_discount < 0 then
    raise exception 'Invalid discount';
  end if;

  if p_loyalty_points is null or p_loyalty_points < 0 then raise exception 'Invalid loyalty points amount'; end if;
  if p_loyalty_points > 0 then
    if p_payment_method = 'credit' then raise exception 'Loyalty points can only be redeemed on cash or card purchases'; end if;
    if p_customer_id is null then raise exception 'Select a registered customer to redeem loyalty points'; end if;
    if p_loyalty_points < 100 then raise exception 'At least 100 points are required for redemption'; end if;
    select id into v_customer_id from public.customers where id=p_customer_id and shop_id=p_shop_id for update;
    if not found then raise exception 'Customer not found in this shop'; end if;
    select coalesce(sum(points),0)::integer into v_loyalty_balance from public.customer_loyalty_points where customer_id=p_customer_id and shop_id=p_shop_id;
    if p_loyalty_points > v_loyalty_balance then raise exception 'Not enough loyalty points. Available: %',v_loyalty_balance; end if;
  end if;
  -- Lock products and calculate the subtotal.
  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(product_id uuid, quantity integer)
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'Invalid product quantity';
    end if;

    select * into v_product
    from public.products
    where id = v_item.product_id and shop_id = p_shop_id
    for update;

    if not found then
      raise exception 'Product not found in this shop';
    end if;

    if p_payment_method <> 'credit'
       and v_product.quantity < v_item.quantity then
      raise exception 'Insufficient stock for %', v_product.product_name;
    end if;

    v_subtotal := v_subtotal
      + (v_product.selling_price * v_item.quantity);
  end loop;

  p_discount := coalesce(p_discount,0) + p_loyalty_points::numeric;
  if p_discount > v_subtotal then
    raise exception 'Discount cannot exceed subtotal';
  end if;

  v_total := v_subtotal - p_discount;
  v_receipt := 'BAJ-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  if p_payment_method = 'credit' then
    v_status := 'pending_approval';
    v_payment_status := 'unpaid';
  else
    v_status := 'completed';
    v_payment_status := 'paid';
  end if;

  insert into public.sales (
    shop_id, receipt_no, customer_id, cashier_id,
    status, payment_status, payment_method,
    subtotal, discount, total
  )
  values (
    p_shop_id, v_receipt, p_customer_id, auth.uid(),
    v_status, v_payment_status, p_payment_method,
    v_subtotal, p_discount, v_total
  )
  returning id into v_sale_id;
  if p_loyalty_points > 0 then
    insert into public.customer_loyalty_points(shop_id,customer_id,sale_id,entry_type,points,note,created_by)
    values(p_shop_id,p_customer_id,v_sale_id,'redeem',-p_loyalty_points,'Redeemed at POS for LKR '||p_loyalty_points,auth.uid());
  end if;

  -- Save item snapshots. Deduct stock immediately only for paid sales.
  for v_item in
    select * from jsonb_to_recordset(p_items)
      as x(product_id uuid, quantity integer)
  loop
    select * into v_product
    from public.products
    where id = v_item.product_id and shop_id = p_shop_id;

    if v_status = 'completed' then
      update public.products
      set quantity = quantity - v_item.quantity,
          updated_at = now()
      where id = v_product.id
        and quantity >= v_item.quantity;

      if not found then
        raise exception 'Insufficient stock for %', v_product.product_name;
      end if;

      insert into public.stock_movements (
        shop_id, product_id, movement_type,
        quantity_change, reference, created_by
      )
      values (
        p_shop_id, v_product.id, 'sale',
        -v_item.quantity, v_receipt, auth.uid()
      );
    end if;

    insert into public.sale_items (
      sale_id, product_id, product_name, product_code,
      quantity, unit_price, unit_cost, line_total
    )
    values (
      v_sale_id, v_product.id, v_product.product_name,
      v_product.product_code, v_item.quantity,
      v_product.selling_price, v_product.cost_price,
      v_product.selling_price * v_item.quantity
    );
  end loop;

  if v_status = 'completed' then
    insert into public.payments (
      shop_id, sale_id, amount, method, received_by
    )
    values (
      p_shop_id, v_sale_id, v_total, p_payment_method, auth.uid()
    );
  end if;

  insert into public.audit_logs (shop_id, user_id, action, details)
  values (
    p_shop_id, auth.uid(), 'sale_created',
    jsonb_build_object(
      'sale_id', v_sale_id,
      'receipt_no', v_receipt,
      'status', v_status,
      'total', v_total
    )
  );

  return jsonb_build_object(
    'sale_id', v_sale_id,
    'receipt_no', v_receipt,
    'status', v_status,
    'total', v_total
  );
end;
$function$
;
revoke all on function public.create_sale(uuid,uuid,text,jsonb,numeric,integer) from public,anon;
grant execute on function public.create_sale(uuid,uuid,text,jsonb,numeric,integer) to authenticated;

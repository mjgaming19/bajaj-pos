-- BAJAJ Batch 5D: business profile and secure shop settings RPC
alter table public.shops
  add column if not exists business_phone text,
  add column if not exists business_address text,
  add column if not exists receipt_prefix text not null default 'BAJ',
  add column if not exists receipt_footer text,
  add column if not exists logo_url text;

create or replace function public.update_shop_settings(
  p_shop_id uuid,
  p_name text,
  p_business_phone text,
  p_business_address text,
  p_receipt_prefix text,
  p_receipt_footer text,
  p_logo_url text
)
returns public.shops
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.shops;
  allowed boolean;
begin
  select
    exists (select 1 from public.platform_admins pa where pa.user_id = auth.uid())
    or exists (
      select 1 from public.shop_members sm
      where sm.shop_id = p_shop_id
        and sm.user_id = auth.uid()
        and sm.role = 'sub_admin'
    )
  into allowed;

  if not allowed then
    raise exception 'You do not have permission to update this shop.';
  end if;

  if nullif(trim(p_name), '') is null then
    raise exception 'Business name is required.';
  end if;

  if nullif(trim(p_receipt_prefix), '') is null
     or length(trim(p_receipt_prefix)) > 10 then
    raise exception 'Receipt prefix must contain 1 to 10 characters.';
  end if;

  if p_logo_url is not null and length(trim(p_logo_url)) > 500 then
    raise exception 'Logo URL is too long.';
  end if;

  update public.shops
  set name = trim(p_name),
      business_phone = nullif(trim(p_business_phone), ''),
      business_address = nullif(trim(p_business_address), ''),
      receipt_prefix = upper(trim(p_receipt_prefix)),
      receipt_footer = nullif(trim(p_receipt_footer), ''),
      logo_url = nullif(trim(p_logo_url), '')
  where id = p_shop_id
  returning * into result;

  if result.id is null then raise exception 'Shop not found.'; end if;
  return result;
end;
$$;

revoke all on function public.update_shop_settings(uuid,text,text,text,text,text,text) from public;
grant execute on function public.update_shop_settings(uuid,text,text,text,text,text,text) to authenticated;

-- BAJAJ Batch 8: barcode support
alter table public.products
  add column if not exists barcode text;

create index if not exists products_shop_barcode_idx
  on public.products(shop_id, barcode)
  where barcode is not null and length(trim(barcode)) > 0;

create unique index if not exists products_shop_barcode_unique
  on public.products(shop_id, barcode)
  where barcode is not null and length(trim(barcode)) > 0;

-- BAJAJ Batch 8: barcode support
-- The barcode column and shop-scoped unique index already exist in this project.
-- Keep this migration idempotent for environments where the column is not present.
alter table public.products
  add column if not exists barcode text;

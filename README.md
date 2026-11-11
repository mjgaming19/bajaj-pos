# BAJAJ Spare Parts POS — Demo 01

A responsive, standalone front-end prototype for a Bajaj-only spare-parts shop management system.

## Run locally

Open `index.html` in a modern browser. No build step is required.

## Demo modules

- Dashboard with illustrative sales and stock figures
- Point of Sale with sample products and cart
- Inventory search and sample product entry
- Sales history
- Customer credit balances and sample repayments
- Supplier placeholder
- Reports with illustrative figures
- Main Admin / Sub-admin / POS user role concept
- Dark and light themes

## Important demo limitations

This is a front-end demonstration only. It does not connect to Supabase, provide real authentication or role enforcement, synchronize devices, store transactions persistently, process payments, or integrate with a physical printer/scanner. All figures and transactions are sample data. Do not use it for live shop operations.

## Planned production architecture

- Supabase Auth and PostgreSQL
- Tenant isolation per shop, enforced with Row Level Security
- Platform Owner, Sub-admin, and POS User permissions
- Audit logs for sensitive actions
- Offline-safe sales queue with duplicate-safe synchronization
- ESC/POS thermal printer and USB barcode scanner compatibility

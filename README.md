# BAJAJ Spare Parts POS

A responsive, browser-based multi-shop POS and management system for Bajaj spare-parts businesses. The front end is a static HTML application and uses Supabase for authentication, PostgreSQL data, row-level security, and Edge Functions.

## Main modules

- Secure sign-in with Main Admin, Sub-admin, and POS User roles
- Multi-shop management with shop-specific data access
- Live point of sale, barcode/product-code lookup, cart, discounts, and receipts
- Inventory management, stock adjustments, low-stock thresholds, and CSV import/export
- Sales history, credit-sale approval, repayments, returns, refunds, and exchanges
- Cashier shifts, opening/closing cash, and cash reconciliation
- Customer profiles, purchase history, credit balances, and loyalty points
- Supplier directory and purchase orders with stock receiving
- Sales analytics, product profitability, cashier performance, and CSV exports
- In-app notifications for low stock, pending credit approvals, and overdue credit balances
- Shop business settings, receipt details, and activity/audit history
- Light and dark themes with responsive desktop and mobile layouts

## Technology

- HTML, CSS, and vanilla JavaScript
- Supabase Auth
- Supabase PostgreSQL with Row Level Security
- Supabase Edge Functions
- GitHub Pages (or another static hosting provider)

## Run locally

Open `index.html` in a modern browser. The app connects to the configured Supabase project, so a valid user account and shop membership are required to sign in.

## Deployment

1. Publish the repository as a static site (for example, with GitHub Pages).
2. Configure the Supabase project URL and publishable key in `index.html`.
3. Apply the SQL migrations in `supabase/migrations` to the matching Supabase project.
4. Deploy the `invite-shop-user` Edge Function and configure its required server-side secrets in Supabase.
5. Create the Main Admin account, add it to `platform_admins`, and create the first shop.
6. Invite or assign Sub-admin and POS User accounts from User Management.

Never put a Supabase secret/service-role key in browser code. The publishable key is intended for client-side use with RLS correctly enabled.

## Important operational notes

- This is an online-first application. Offline sales queuing and automatic background synchronization are not implemented.
- In-app alerts are available; SMS, WhatsApp, and email reminder delivery are not configured.
- Receipts can be rendered/printed by the browser. Direct ESC/POS printer integration and hardware-specific scanner integrations are not included.
- Use a separate Supabase project for development and production, and take database backups before production schema changes.

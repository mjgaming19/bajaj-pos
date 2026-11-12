# BAJAJ POS — Final Launch Checklist

## Automated checks completed
- [x] Front-end JavaScript parses successfully.
- [x] No Supabase service-role key or secret-key marker is present in browser code.
- [x] Row Level Security is enabled on all 25 public application tables.
- [x] Anonymous role has no direct table privileges on the public application tables.
- [x] Internal trigger functions cannot be invoked directly by anon or authenticated API roles.
- [x] Subscription plan and shop-subscription records exist.
- [x] Database triggers enforce the configured per-shop product and user limits.
- [x] `invite-shop-user` Edge Function is deployed and JWT verification is enabled.

## Required browser acceptance tests
Run these using separate test accounts and test shops before onboarding real customers.

### Authentication and roles
- [ ] Main Admin can sign in, see all shops, create a shop and manage subscriptions.
- [ ] Sub-admin can only access their assigned shop and shop-management pages.
- [ ] POS User can access checkout and permitted cashier/customer pages only.
- [ ] A user from Shop A cannot read or modify Shop B data.
- [ ] Sign out and expired-session behavior return to the login screen.

### Inventory and purchasing
- [ ] Create, edit, adjust and delete a test product.
- [ ] CSV import/export preserves product codes, cost prices, selling prices and quantities.
- [ ] Low-stock alert appears and resolves after replenishment.
- [ ] Create a purchase order and receive stock; verify quantities and movement history.

### POS, shifts and credit
- [ ] Complete a cash sale and confirm stock decreases exactly once.
- [ ] Complete a card sale and print a receipt.
- [ ] Submit a credit sale, approve it as a manager and record a partial repayment.
- [ ] Open and close a cashier shift; compare expected and counted cash.
- [ ] Test discount, customer selection, loyalty earn/redeem and receipt details.

### Returns, expenses and reporting
- [ ] Process a partial return and verify stock and refund totals.
- [ ] Process an exchange and verify replacement stock.
- [ ] Add, edit and delete a test expense.
- [ ] Compare gross profit, expenses and net profit for a known test period.
- [ ] Check sales, customer, supplier, expense and analytics CSV exports.

### SaaS subscriptions
- [ ] Confirm a new shop receives a 14-day Starter trial.
- [ ] Change a shop's plan and confirm the plan limits update.
- [ ] Confirm product creation is blocked at the product limit.
- [ ] Confirm adding users is blocked at the user limit.
- [ ] Confirm expired or suspended subscriptions cannot add products or users.
- [ ] Verify plan prices and statuses are correct before selling subscriptions.

### Devices and recovery
- [ ] Test the full workflow on the actual shop computer and a phone.
- [ ] Test the receipt printer and barcode scanner used by the shop.
- [ ] Export and restore a backup using a safe test copy.
- [ ] Confirm the production Supabase project has backups and appropriate access controls.

## Production setup still required
- Enable Supabase leaked-password protection in **Authentication → Security and Protection**.
- Set real Starter/Professional/custom plan prices in the Main Admin subscription screen.
- Connect a payment provider and implement verified payment webhooks before charging subscriptions. The current subscription screen records plans and statuses; it does not collect payments or run automatic recurring billing.
- Confirm the production domain, Supabase Auth redirect URLs, email templates and invitation delivery.
- Keep the Supabase service-role key only in server-side secrets. Never place it in `index.html`.
- Complete the browser acceptance tests above before using live customer or financial data.

## Known scope notes
- Subscription product/user limits are enforced by database triggers.
- Subscription statuses are managed by the Main Admin. Automatic payment collection and automatic suspension based on failed payment are not configured.
- This checklist records test coverage to perform; unchecked browser tests have not been claimed as completed.


-- BAJAJ security hardening: consolidate shop membership policies.
-- Platform admins retain full control; sub-admins may manage POS-user rows only.
drop policy if exists "Manage shop memberships" on public.shop_members;
drop policy if exists "Platform admins and sub-admins add shop members" on public.shop_members;
drop policy if exists "Platform admins and sub-admins remove shop members" on public.shop_members;
drop policy if exists "Remove shop memberships" on public.shop_members;
drop policy if exists "Platform admins and sub-admins update shop members" on public.shop_members;
drop policy if exists "Update shop memberships" on public.shop_members;
drop policy if exists "Shop admins manage memberships safely" on public.shop_members;
drop policy if exists "Shop admins update memberships safely" on public.shop_members;
drop policy if exists "Shop admins remove memberships safely" on public.shop_members;

create policy "Shop admins manage memberships safely"
on public.shop_members for insert to authenticated
with check (
  (select public.is_platform_admin())
  or (
    (select public.has_shop_role(shop_id, array['sub_admin']::text[]))
    and role = 'pos_user'
  )
);

create policy "Shop admins update memberships safely"
on public.shop_members for update to authenticated
using (
  (select public.is_platform_admin())
  or (
    (select public.has_shop_role(shop_id, array['sub_admin']::text[]))
    and role = 'pos_user'
  )
)
with check (
  (select public.is_platform_admin())
  or (
    (select public.has_shop_role(shop_id, array['sub_admin']::text[]))
    and role = 'pos_user'
  )
);

create policy "Shop admins remove memberships safely"
on public.shop_members for delete to authenticated
using (
  (select public.is_platform_admin())
  or (
    (select public.has_shop_role(shop_id, array['sub_admin']::text[]))
    and role = 'pos_user'
  )
);

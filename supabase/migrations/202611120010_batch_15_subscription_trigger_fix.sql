
create or replace function public.log_subscription_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.subscription_events(shop_id, subscription_id, event_type, details, actor_id)
    values(new.shop_id, new.id, 'subscription_created',
      jsonb_build_object('plan_id',new.plan_id,'status',new.status,'trial_ends_at',new.trial_ends_at), auth.uid());
    return new;
  end if;
  if row(new.plan_id,new.status,new.billing_cycle,new.trial_ends_at,new.current_period_end,new.cancel_at_period_end)
     is distinct from
     row(old.plan_id,old.status,old.billing_cycle,old.trial_ends_at,old.current_period_end,old.cancel_at_period_end) then
    insert into public.subscription_events(shop_id, subscription_id, event_type, details, actor_id)
    values(new.shop_id, new.id, 'subscription_updated',
      jsonb_build_object('old_status',old.status,'new_status',new.status,'old_plan_id',old.plan_id,'new_plan_id',new.plan_id,
                         'trial_ends_at',new.trial_ends_at,'current_period_end',new.current_period_end), auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists shop_subscriptions_log_change on public.shop_subscriptions;
create trigger shop_subscriptions_log_change
after insert or update on public.shop_subscriptions
for each row execute function public.log_subscription_change();

create or replace function public.touch_shop_subscription_updated_at()
returns trigger language plpgsql set search_path=public as $$
begin new.updated_at=now(); return new; end;
$$;
drop trigger if exists shop_subscriptions_touch_updated_at on public.shop_subscriptions;
create trigger shop_subscriptions_touch_updated_at
before update on public.shop_subscriptions
for each row execute function public.touch_shop_subscription_updated_at();

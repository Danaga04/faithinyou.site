-- Sacred Chant: Digistore24 token fulfillment
-- Run this in Supabase SQL Editor before deploying the Edge Function.

create table if not exists public.digistore24_token_orders (
  transaction_key text primary key,
  order_id text not null,
  order_item_id text,
  product_id text not null,
  buyer_email text not null,
  user_id uuid references auth.users(id) on delete set null,
  tokens integer not null check (tokens > 0),
  status text not null check (status in ('pending','paid','refunded','chargeback')),
  created_at timestamptz not null default now(),
  credited_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.digistore24_token_orders enable row level security;
revoke all on public.digistore24_token_orders from public, anon, authenticated;

create or replace function public.credit_digistore24_order(
  p_transaction_key text,
  p_order_id text,
  p_order_item_id text,
  p_product_id text,
  p_buyer_email text,
  p_event text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tokens integer;
  v_user_id uuid;
  v_inserted text;
begin
  if coalesce(p_transaction_key, '') = '' or coalesce(p_order_id, '') = ''
     or coalesce(p_product_id, '') = '' then
    raise exception 'missing_order_fields';
  end if;

  if p_event in ('on_refund', 'on_chargeback') then
    update public.digistore24_token_orders
       set status = case when p_event = 'on_refund' then 'refunded' else 'chargeback' end,
           updated_at = now()
     where transaction_key = p_transaction_key
       and status in ('pending','paid');
    return 'refund_or_chargeback_recorded';
  end if;

  if p_event not in ('on_payment', 'on_payment_subscription_signup') then
    return 'event_ignored';
  end if;

  v_tokens := case p_product_id
    when '734741' then 100
    when '734742' then 500
    when '734743' then 1000
    else null
  end;

  if v_tokens is null then
    raise exception 'unmapped_product_id';
  end if;

  select u.id into v_user_id
    from auth.users as u
   where lower(u.email) = lower(trim(coalesce(p_buyer_email, '')))
   limit 1;

  insert into public.digistore24_token_orders
    (transaction_key, order_id, order_item_id, product_id, buyer_email, user_id, tokens, status, credited_at)
  values
    (p_transaction_key, p_order_id, nullif(p_order_item_id, ''), p_product_id,
     lower(trim(coalesce(p_buyer_email, ''))), v_user_id, v_tokens,
     case when v_user_id is null then 'pending' else 'paid' end,
     case when v_user_id is null then null else now() end)
  on conflict (transaction_key) do nothing
  returning transaction_key into v_inserted;

  if v_inserted is null then
    return 'duplicate_ignored';
  end if;

  if v_user_id is null then
    return 'pending_account_match';
  end if;

  update public.token_balances
     set balance = balance + v_tokens,
         updated_at = now()
   where user_id = v_user_id;

  if not found then
    raise exception 'token_balance_not_found';
  end if;

  return 'credited';
end;
$$;

revoke all on function public.credit_digistore24_order(text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.credit_digistore24_order(text,text,text,text,text,text) to service_role;

create or replace function public.claim_pending_digistore24_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text;
  v_order record;
  v_count integer := 0;
begin
  if v_user_id is null then
    raise exception 'not_authenticated';
  end if;

  select lower(u.email) into v_email
    from auth.users as u
   where u.id = v_user_id;

  if v_email is null then
    raise exception 'account_email_not_found';
  end if;

  for v_order in
    select d.transaction_key, d.tokens
      from public.digistore24_token_orders as d
     where d.status = 'pending'
       and lower(d.buyer_email) = v_email
     for update
  loop
    update public.token_balances
       set balance = balance + v_order.tokens,
           updated_at = now()
     where user_id = v_user_id;

    if not found then
      raise exception 'token_balance_not_found';
    end if;

    update public.digistore24_token_orders
       set user_id = v_user_id,
           status = 'paid',
           credited_at = now(),
           updated_at = now()
     where transaction_key = v_order.transaction_key
       and status = 'pending';

    if found then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.claim_pending_digistore24_orders() from public, anon;
grant execute on function public.claim_pending_digistore24_orders() to authenticated;

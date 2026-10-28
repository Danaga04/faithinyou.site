-- Sacred Chant: unify daily rewards with the purchased Light Token wallet.
-- Apply this migration in the Supabase SQL Editor (or deploy migrations) before relying on the new timer.

create table if not exists public.daily_light_claims (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_claimed_at timestamptz not null default now()
);

alter table public.daily_light_claims enable row level security;
revoke all on public.daily_light_claims from public, anon, authenticated;

create or replace function public.claim_daily_light()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_claimed_at timestamptz;
  v_balance integer;
begin
  if v_user_id is null then
    raise exception 'not_authenticated';
  end if;

  -- Claim atomically; concurrent taps/devices cannot award twice in 24 hours.
  insert into public.daily_light_claims (user_id, last_claimed_at)
  values (v_user_id, now())
  on conflict (user_id) do update
    set last_claimed_at = excluded.last_claimed_at
    where public.daily_light_claims.last_claimed_at <= now() - interval '24 hours'
  returning last_claimed_at into v_claimed_at;

  if not found then
    raise exception 'daily_reward_already_claimed';
  end if;

  -- This is the same token_balances wallet used by Digistore24 purchases and spend_light().
  update public.token_balances
     set balance = balance + 10,
         updated_at = now()
   where user_id = v_user_id
   returning balance into v_balance;

  if not found then
    insert into public.token_balances (user_id, balance, updated_at)
    values (v_user_id, 10, now())
    returning balance into v_balance;
  end if;

  return v_balance;
end;
$$;

revoke all on function public.claim_daily_light() from public, anon;
grant execute on function public.claim_daily_light() to authenticated;

create or replace function public.get_daily_light_status()
returns timestamptz
language sql
security definer
set search_path = ''
as $$
  select c.last_claimed_at
    from public.daily_light_claims c
   where c.user_id = auth.uid();
$$;

revoke all on function public.get_daily_light_status() from public, anon;
grant execute on function public.get_daily_light_status() to authenticated;

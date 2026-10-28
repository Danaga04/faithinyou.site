-- Sacred Chant: unify daily rewards and Digistore24 purchases in token_balances.
-- Apply this migration in the Supabase SQL Editor before relying on the updated reward flow.

create table if not exists public.sacredchant_daily_claims (
  user_id uuid not null references auth.users(id) on delete cascade,
  reward_date date not null default (now() at time zone 'utc')::date,
  tokens integer not null default 10 check (tokens > 0),
  created_at timestamptz not null default now(),
  primary key (user_id, reward_date)
);

alter table public.sacredchant_daily_claims enable row level security;
revoke all on public.sacredchant_daily_claims from public, anon, authenticated;

create or replace function public.claim_daily_light()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_balance integer;
  v_reward_date date := (now() at time zone 'utc')::date;
begin
  if v_user_id is null then
    raise exception 'not_authenticated';
  end if;

  -- The same balance row is used for both purchased and daily tokens.
  insert into public.token_balances (user_id, balance, updated_at)
  values (v_user_id, 0, now())
  on conflict (user_id) do nothing;

  insert into public.sacredchant_daily_claims (user_id, reward_date, tokens)
  values (v_user_id, v_reward_date, 10)
  on conflict (user_id, reward_date) do nothing;

  if not found then
    raise exception 'daily_reward_already_claimed';
  end if;

  update public.token_balances
     set balance = balance + 10,
         updated_at = now()
   where user_id = v_user_id
   returning balance into v_balance;

  return v_balance;
end;
$$;

revoke all on function public.claim_daily_light() from public, anon;
grant execute on function public.claim_daily_light() to authenticated;

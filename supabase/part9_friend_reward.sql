-- ===== 9回目:はじめてフレンドができたときのプレゼント(1アカウント1回だけ) =====
-- もらった記録。1人1行なので、フレンドを外して付け直しても二度はもらえない
create table if not exists public.friend_rewards (
  user_id uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.friend_rewards enable row level security;
-- フレンドが1人以上いて、まだもらっていなければ記録して true を返す(もらえるのはこの1回だけ)
create or replace function public.friend_reward() returns boolean
  language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if public.friend_count(auth.uid()) < 1 then return false; end if;
  insert into public.friend_rewards (user_id) values (auth.uid()) on conflict do nothing;
  return found;
end $$;
revoke execute on function public.friend_reward() from public, anon;
grant execute on function public.friend_reward() to authenticated;

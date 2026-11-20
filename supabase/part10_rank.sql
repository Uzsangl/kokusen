-- ===== 10回目:ランク戦(自動マッチング・勝ったほうに +1) =====
-- レートの増減:これまでどおり奪い合い。勝ったときだけ、さらに +1(1試合ごとに全体のポイントが1増える)
create or replace function public.rate_delta(my_base int, foe_base int, s real) returns int
  language sql immutable set search_path = '' as
  $$ select case when s is null then 0
       else round(32 * (s - 1 / (1 + power(10, (foe_base - my_base) / 400.0))))::int
            + case when s = 1 then 1 else 0 end end $$;

-- ランク戦の待ち列(本人も直接は読み書きできない。下の関数からだけ使う)
create table if not exists public.rank_queue (
  user_id uuid primary key references auth.users on delete cascade,
  rating int not null,
  code text,
  foe uuid,
  joined_at timestamptz not null default now(),
  seen_at timestamptz not null default now()
);
alter table public.rank_queue enable row level security;

-- 相手を探す(2秒おきに呼ぶ)。相手が決まれば部屋の合言葉を返す。まだなら null
-- レートの差は、待った時間が長いほど広く許す(100 + 1秒ごとに10)
create or replace function public.rank_find() returns text
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); r int; mine public.rank_queue; f public.rank_queue; c text;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  select rating into r from public.profiles where id = me;
  if r is null then raise exception 'プロフィールがありません'; end if;
  perform pg_advisory_xact_lock(7262010);   -- 同時に二組が同じ人を取り合わないように、一人ずつ順に処理する
  delete from public.rank_queue where seen_at < now() - interval '15 seconds';
  select * into mine from public.rank_queue where user_id = me;
  if found and mine.code is not null then
    delete from public.rank_queue where user_id = me;
    return mine.code;
  end if;
  if not found then
    insert into public.rank_queue (user_id, rating) values (me, r) returning * into mine;
  else
    update public.rank_queue set seen_at = now(), rating = r where user_id = me;
  end if;
  select * into f from public.rank_queue q
    where q.user_id <> me and q.code is null
      and abs(q.rating - r) <= 100 + 10 * extract(epoch from (now() - least(q.joined_at, mine.joined_at)))
    order by q.joined_at limit 1;
  if not found then return null; end if;
  c := public.friend_rand(10);
  update public.rank_queue set code = c, foe = me, seen_at = now() where user_id = f.user_id;
  delete from public.rank_queue where user_id = me;
  return c;
end $$;

-- 探すのをやめる
create or replace function public.rank_leave() returns void
  language sql security definer set search_path = '' as
  $$ delete from public.rank_queue where user_id = auth.uid() $$;

revoke execute on function public.rank_find() from public, anon;
revoke execute on function public.rank_leave() from public, anon;
grant execute on function public.rank_find() to authenticated;
grant execute on function public.rank_leave() to authenticated;

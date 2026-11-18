-- ===== 8回目:フレンド・ログイン中の表示・フレンドのソロ観戦 =====
-- フレンドコード(8文字)と、ソロ観戦の部屋の鍵(16文字)。本人とフレンドにしか見せないので、表は関数だけが読み書きする
create table if not exists public.friend_keys (
  user_id uuid primary key references auth.users on delete cascade,
  friend_code text not null unique,
  watch_key text not null,
  watch_off boolean not null default false   -- true なら、フレンドの観戦を受け付けない
);
alter table public.friend_keys enable row level security;
-- フレンドの関係:a が b に申請した。ok = true でフレンド
create table if not exists public.friend_links (
  a uuid not null references auth.users on delete cascade,
  b uuid not null references auth.users on delete cascade,
  ok boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (a, b),
  check (a <> b)
);
alter table public.friend_links enable row level security;
-- 今の状況(ソロに挑戦中など)と、最後に動いていた時刻(ログイン中かどうかの判定に使う)
create table if not exists public.user_status (
  user_id uuid primary key references auth.users on delete cascade,
  st jsonb not null default '{}',
  seen_at timestamptz not null default now()
);
alter table public.user_status enable row level security;

-- まぎらわしい文字(0/O・1/I)を除いたランダムな文字列
create or replace function public.friend_rand(n int) returns text
  language sql volatile set search_path = '' as
  $$ select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, n) $$;

-- 自分のフレンドコード・観戦の鍵・観戦を受け付けるか(まだなければ作る)
create or replace function public.friend_me() returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); r public.friend_keys;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into r from public.friend_keys where user_id = me;
  if not found then
    loop
      begin
        insert into public.friend_keys (user_id, friend_code, watch_key)
          values (me, public.friend_rand(8), public.friend_rand(16)) returning * into r;
        exit;
      exception when unique_violation then null;   -- コードが重なったら作り直す
      end;
    end loop;
  end if;
  return json_build_object('code', r.friend_code, 'key', r.watch_key, 'off', r.watch_off);
end $$;

-- フレンドの数(承認済み)
create or replace function public.friend_count(u uuid) returns int
  language sql stable security definer set search_path = '' as
  $$ select count(*)::int from public.friend_links where ok and (a = u or b = u) $$;

-- フレンド申請(フレンドコードで)。相手からも申請が来ていれば、その場でフレンドになる。フレンドは30人まで
create or replace function public.friend_request(p_code text) returns text
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); t uuid;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  select user_id into t from public.friend_keys where friend_code = upper(trim(p_code));
  if t is null then raise exception 'そのフレンドコードは見つかりません' using errcode = 'KF001'; end if;
  if t = me then raise exception '自分のフレンドコードです' using errcode = 'KF002'; end if;
  if exists (select 1 from public.friend_links where ok and ((a = me and b = t) or (a = t and b = me))) then return 'already'; end if;
  if public.friend_count(me) >= 30 then raise exception 'フレンドは30人までです' using errcode = 'KF003'; end if;
  if exists (select 1 from public.friend_links where a = t and b = me) then
    if public.friend_count(t) >= 30 then raise exception '相手のフレンドがいっぱいです' using errcode = 'KF004'; end if;
    update public.friend_links set ok = true where a = t and b = me;
    return 'ok';
  end if;
  insert into public.friend_links (a, b) values (me, t) on conflict do nothing;
  return 'sent';
end $$;

-- 届いた申請に答える(p_ok = true で承認、false で断る)
create or replace function public.friend_answer(p_from uuid, p_ok boolean) returns void
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_ok then
    if public.friend_count(me) >= 30 then raise exception 'フレンドは30人までです' using errcode = 'KF003'; end if;
    if public.friend_count(p_from) >= 30 then raise exception '相手のフレンドがいっぱいです' using errcode = 'KF004'; end if;
    update public.friend_links set ok = true where a = p_from and b = me;
  else
    delete from public.friend_links where a = p_from and b = me and not ok;
  end if;
end $$;

-- フレンドを外す(出した申請の取り消しにも使う)。外したら自分の観戦の鍵を作り直して、外した相手が観戦できないようにする
create or replace function public.friend_remove(p_other uuid) returns void
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  delete from public.friend_links where (a = me and b = p_other) or (a = p_other and b = me);
  update public.friend_keys set watch_key = public.friend_rand(16) where user_id = me;
end $$;

-- 一覧:フレンド(ok)・届いた申請(in)・出した申請(out)。観戦の鍵は、フレンドで観戦を受け付けている人のぶんだけ返す
create or replace function public.friend_list() returns json
  language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(x order by x.state, x.seen desc nulls last), '[]'::json) from (
    select o.id, p.name, p.fav, p.title, p.rating,
      case when l.ok then 'ok' when l.b = auth.uid() then 'in' else 'out' end as state,
      case when l.ok then s.st end as st,
      case when l.ok then s.seen_at end as seen,
      case when l.ok and not coalesce(k.watch_off, false) then k.watch_key end as key
    from public.friend_links l
    cross join lateral (select case when l.a = auth.uid() then l.b else l.a end as id) o
    join public.profiles p on p.id = o.id
    left join public.user_status s on s.user_id = o.id
    left join public.friend_keys k on k.user_id = o.id
    where auth.uid() is not null and (l.a = auth.uid() or l.b = auth.uid())
  ) x $$;

-- 今の状況を知らせる(ページを開いている間、1分ごとと、対戦の始まり・終わりに呼ぶ)
create or replace function public.status_set(p_st jsonb) returns void
  language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  insert into public.user_status (user_id, st, seen_at) values (auth.uid(), coalesce(p_st, '{}'), now())
    on conflict (user_id) do update set st = excluded.st, seen_at = now();
end $$;

-- フレンドの観戦を受け付けるか
create or replace function public.friend_watch_off(p_off boolean) returns void
  language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  update public.friend_keys set watch_off = p_off where user_id = auth.uid();
end $$;

revoke execute on function public.friend_rand(int) from public, anon, authenticated;
revoke execute on function public.friend_count(uuid) from public, anon, authenticated;
revoke execute on function public.friend_me() from public, anon;
revoke execute on function public.friend_request(text) from public, anon;
revoke execute on function public.friend_answer(uuid, boolean) from public, anon;
revoke execute on function public.friend_remove(uuid) from public, anon;
revoke execute on function public.friend_list() from public, anon;
revoke execute on function public.status_set(jsonb) from public, anon;
revoke execute on function public.friend_watch_off(boolean) from public, anon;
grant execute on function public.friend_me() to authenticated;
grant execute on function public.friend_request(text) to authenticated;
grant execute on function public.friend_answer(uuid, boolean) to authenticated;
grant execute on function public.friend_remove(uuid) to authenticated;
grant execute on function public.friend_list() to authenticated;
grant execute on function public.status_set(jsonb) to authenticated;
grant execute on function public.friend_watch_off(boolean) to authenticated;

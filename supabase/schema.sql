-- 刻戦のアカウント用の表(Supabase の SQL Editor で実行する)

-- ===== 1回目(最初に実行したもの) =====
-- プレイヤー情報(名前・レーティング)。ランキング用に誰でも読める
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null default '名無し' check (char_length(name) between 1 and 12),
  rating int not null default 1500,
  wins int not null default 0,
  losses int not null default 0,
  cleared text[] not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "誰でも読める" on public.profiles for select using (true);
create policy "自分の行だけ作れる" on public.profiles for insert with check (auth.uid() = id);
create policy "自分の行だけ書ける" on public.profiles for update using (auth.uid() = id);

-- ===== 2回目:非公開の記録を分け、称号の列を足す =====
-- クリア記録などは、本人だけが読める表に移す(profiles は全員に公開されるため)
create table if not exists public.progress (
  id uuid primary key references auth.users on delete cascade,
  cleared text[] not null default '{}',
  stats jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.progress enable row level security;
create policy "自分だけ読める" on public.progress for select using (auth.uid() = id);
create policy "自分だけ作れる" on public.progress for insert with check (auth.uid() = id);
create policy "自分だけ書ける" on public.progress for update using (auth.uid() = id);
insert into public.progress (id, cleared) select id, cleared from public.profiles on conflict (id) do nothing;
alter table public.profiles drop column if exists cleared;
-- 称号:選んでいる称号と、解放した称号の一覧(公開)
alter table public.profiles add column if not exists title text not null default '';
alter table public.profiles add column if not exists titles text[] not null default '{}';

-- ===== 3回目:お気に入りキャラ =====
alter table public.profiles add column if not exists fav text not null default '';

-- ===== 4回目:招待コード =====
-- 招待コード:アカウントのIDから作る8文字(公開)。コードから招待した人を探すのに使う
alter table public.profiles add column if not exists invite_code text generated always as (upper(substr(md5(id::text), 1, 8))) stored;
create unique index if not exists profiles_invite_code on public.profiles (invite_code);
-- 招待の記録:招待された人1人につき1行(1回しか使えない)。自分を招待はできない
create table if not exists public.invites (
  invitee uuid primary key references auth.users on delete cascade,
  inviter uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  check (invitee <> inviter)
);
alter table public.invites enable row level security;
-- 作ってから1日以内のアカウントか(サーバーの登録日時で確かめる)
create or replace function public.is_new_account() returns boolean
  language sql stable security definer set search_path = '' as
  $$ select exists (select 1 from auth.users where id = auth.uid() and created_at > now() - interval '1 day') $$;
create policy "招待:本人と招待した人だけ見られる" on public.invites for select using (auth.uid() = invitee or auth.uid() = inviter);
create policy "招待:作って1日以内の本人だけ登録できる" on public.invites for insert with check (auth.uid() = invitee and public.is_new_account());

-- ===== 5回目:招待は1人5人まで(アカウント量産の対策) =====
-- 招待した人数を数える(招待された側からは他人の行が見えないため、数だけを返す関数にする)
create or replace function public.invite_count(u uuid) returns int
  language sql stable security definer set search_path = '' as
  $$ select count(*)::int from public.invites where inviter = u $$;
drop policy if exists "招待:作って1日以内の本人だけ登録できる" on public.invites;
create policy "招待:作って1日以内の本人だけ・招待は5人まで" on public.invites for insert
  with check (auth.uid() = invitee and public.is_new_account() and public.invite_count(inviter) < 5);

-- ===== 6回目:レートをサーバーで計算する(書き換え対策)・アカウント削除 =====
-- これまではレートを各プレイヤーのブラウザが計算して自分で保存していたので、好きな数字に書き換えられた。
-- ここからは、レート・勝ち数・負け数はサーバーの関数だけが書き換える。
--
-- 仕組み:
--   1. 対戦が始まると、両方の端末が rate_start を呼ぶ。呼んだ人はその時点で「仮の負け」になる(切断対策)。
--   2. 決着したら、両方の端末が rate_finish で結果(勝ち1・引き分け0.5・負け0)を申告する。
--   3. 二人の申告が食い違ったら(両方が「勝った」など)、二人とも負けのまま。うそをついても得をしない。
--   4. 相手が申告しないまま(切断など)なら、相手は仮の負けのままなので、自分の申告をそのまま反映する。
--      あとから相手が食い違う申告をしたら、3 のとおり二人とも負けに直す。
--   5. 相手が rate_start を呼んでいない対戦は、なかったことにする(レートを元に戻す)。

-- 対戦の記録(関数だけが読み書きする。RLS を有効にして、決まりを1つも作らないので、外からは見えない)
create table if not exists public.matches (
  key text not null check (char_length(key) between 8 and 100),   -- 両方の端末が同じ値を作る、対戦ごとの合言葉
  a uuid not null references auth.users on delete cascade,        -- IDが小さいほう
  b uuid not null references auth.users on delete cascade,        -- IDが大きいほう
  a_base int not null, b_base int not null,                       -- 対戦が始まったときのレート
  a_started boolean not null default false, b_started boolean not null default false,
  a_claim real, b_claim real,                                     -- 申告した結果(まだなら null)
  a_applied real, b_applied real,                                 -- いまレートに反映している結果(反映なしなら null)
  created_at timestamptz not null default now(),
  primary key (a, b, key),
  check (a < b)
);
alter table public.matches enable row level security;
revoke all on public.matches from anon, authenticated;

-- レートの決まり(index.html の RATING_K と同じ値にする)
-- 結果 s がレートに与える増減。s が null なら 0
create or replace function public.rate_delta(my_base int, foe_base int, s real) returns int
  language sql immutable set search_path = '' as
  $$ select case when s is null then 0
       else round(32 * (s - 1 / (1 + power(10, (foe_base - my_base) / 400.0))))::int end $$;

-- 反映している結果を old から new に替える(レート・勝ち数・負け数を差し引きで直す)
create or replace function public.rate_apply(u uuid, my_base int, foe_base int, old real, new real) returns void
  language sql security definer set search_path = '' as
  $$ update public.profiles set
       rating = greatest(100, rating - public.rate_delta(my_base, foe_base, old) + public.rate_delta(my_base, foe_base, new)),
       wins   = greatest(0, wins   - (case when old = 1 then 1 else 0 end) + (case when new = 1 then 1 else 0 end)),
       losses = greatest(0, losses - (case when old = 0 then 1 else 0 end) + (case when new = 0 then 1 else 0 end)),
       updated_at = now()
     where id = u and old is distinct from new $$;

-- 対戦開始:呼んだ人を「仮の負け」にする。戻り値は自分の新しいレート・勝ち数・負け数
create or replace function public.rate_start(p_key text, p_foe uuid) returns json
  language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  x uuid; y uuid; m public.matches; is_a boolean;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_foe is null or p_foe = me then raise exception '相手が正しくありません'; end if;
  x := least(me, p_foe); y := greatest(me, p_foe); is_a := (me = x);
  insert into public.matches (key, a, b, a_base, b_base)
    select p_key, x, y, pa.rating, pb.rating from public.profiles pa, public.profiles pb where pa.id = x and pb.id = y
    on conflict do nothing;
  select * into m from public.matches where a = x and b = y and key = p_key for update;
  if not found then raise exception '相手のアカウントが見つかりません'; end if;
  if m.created_at < now() - interval '10 minutes' then raise exception 'この対戦には、もう参加できません'; end if;
  if is_a and not m.a_started then
    update public.matches set a_started = true, a_applied = 0 where a = x and b = y and key = p_key;
    perform public.rate_apply(me, m.a_base, m.b_base, null, 0);
  elsif not is_a and not m.b_started then
    update public.matches set b_started = true, b_applied = 0 where a = x and b = y and key = p_key;
    perform public.rate_apply(me, m.b_base, m.a_base, null, 0);
  end if;
  return (select json_build_object('rating', rating, 'wins', wins, 'losses', losses) from public.profiles where id = me);
end $$;

-- 決着:結果を申告する(1試合に1回だけ)。戻り値は自分の新しいレート・勝ち数・負け数
create or replace function public.rate_finish(p_key text, p_foe uuid, p_score real) returns json
  language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  x uuid; y uuid; m public.matches; is_a boolean;
  na real; nb real;   -- これから反映する結果
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_score is null or p_score not in (0, 0.5, 1) then raise exception '結果が正しくありません'; end if;
  x := least(me, p_foe); y := greatest(me, p_foe); is_a := (me = x);
  select * into m from public.matches where a = x and b = y and key = p_key for update;
  if found
     and (case when is_a then m.a_started else m.b_started end)
     and (case when is_a then m.a_claim else m.b_claim end) is null
     and m.created_at > now() - interval '3 hours' then
    -- 始まって15秒たたないうちの「勝ち」「引き分け」は受け付けない(負けのまま)
    if p_score > 0 and m.created_at > now() - interval '15 seconds' then p_score := 0; end if;
    if is_a then m.a_claim := p_score; else m.b_claim := p_score; end if;
    if not (m.a_started and m.b_started) then
      na := null; nb := null;                                  -- 相手が始めていない:なかったことにする
    elsif m.a_claim is not null and m.b_claim is not null then
      if m.a_claim + m.b_claim > 1 then na := 0; nb := 0;      -- 食い違い:二人とも負け
      else na := m.a_claim; nb := m.b_claim; end if;
    else
      na := coalesce(m.a_claim, 0); nb := coalesce(m.b_claim, 0);   -- 相手はまだ:相手は仮の負けのまま
    end if;
    perform public.rate_apply(x, m.a_base, m.b_base, m.a_applied, na);
    perform public.rate_apply(y, m.b_base, m.a_base, m.b_applied, nb);
    update public.matches set a_claim = m.a_claim, b_claim = m.b_claim, a_applied = na, b_applied = nb
      where a = x and b = y and key = p_key;
  end if;
  return (select json_build_object('rating', rating, 'wins', wins, 'losses', losses) from public.profiles where id = me);
end $$;

-- アカウントの削除:本人のアカウントと、ひもづく記録(プレイヤー情報・非公開の記録・招待・対戦の記録)をすべて消す
create or replace function public.delete_my_account() returns void
  language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- 関数を呼べるのはログインした人だけ。中だけで使う関数は外から呼べないようにする
revoke execute on function public.rate_delta(int, int, real) from public, anon, authenticated;
revoke execute on function public.rate_apply(uuid, int, int, real, real) from public, anon, authenticated;
revoke execute on function public.rate_start(text, uuid) from public, anon;
revoke execute on function public.rate_finish(text, uuid, real) from public, anon;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.rate_start(text, uuid) to authenticated;
grant execute on function public.rate_finish(text, uuid, real) to authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- プレイヤーが自分で書き換えられる列を限る。rating・wins・losses は、上の関数だけが書き換える。
-- ※あとで profiles に「プレイヤーが自分で書く列」を足すときは、ここと同じ grant をその列にも足すこと
revoke insert, update on public.profiles from anon, authenticated;
grant insert (id, name) on public.profiles to authenticated;
grant update (name, title, titles, fav, updated_at) on public.profiles to authenticated;

-- ===== 7回目:同じ相手とのレート戦は1日5回まで(2つのアカウントでレートを上げる不正の対策) =====
-- rate_start を置き換える。上限を超えたら、エラー KS001 を返してレートを動かさない(対戦そのものはできる)
create or replace function public.rate_start(p_key text, p_foe uuid) returns json
  language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  x uuid; y uuid; m public.matches; is_a boolean;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_foe is null or p_foe = me then raise exception '相手が正しくありません'; end if;
  x := least(me, p_foe); y := greatest(me, p_foe); is_a := (me = x);
  -- 同じ相手とのレート戦は1日5回まで(二人とも始めた対戦だけを数える)。6回目からはレートを動かさない
  if not exists (select 1 from public.matches where a = x and b = y and key = p_key)
     and (select count(*) from public.matches where a = x and b = y and a_started and b_started and created_at > now() - interval '1 day') >= 5 then
    raise exception '同じ相手とのレート戦は1日5回までです' using errcode = 'KS001';
  end if;
  insert into public.matches (key, a, b, a_base, b_base)
    select p_key, x, y, pa.rating, pb.rating from public.profiles pa, public.profiles pb where pa.id = x and pb.id = y
    on conflict do nothing;
  select * into m from public.matches where a = x and b = y and key = p_key for update;
  if not found then raise exception '相手のアカウントが見つかりません'; end if;
  if m.created_at < now() - interval '10 minutes' then raise exception 'この対戦には、もう参加できません'; end if;
  if is_a and not m.a_started then
    update public.matches set a_started = true, a_applied = 0 where a = x and b = y and key = p_key;
    perform public.rate_apply(me, m.a_base, m.b_base, null, 0);
  elsif not is_a and not m.b_started then
    update public.matches set b_started = true, b_applied = 0 where a = x and b = y and key = p_key;
    perform public.rate_apply(me, m.b_base, m.a_base, null, 0);
  end if;
  return (select json_build_object('rating', rating, 'wins', wins, 'losses', losses) from public.profiles where id = me);
end $$;
revoke execute on function public.rate_start(text, uuid) from public, anon;
grant execute on function public.rate_start(text, uuid) to authenticated;

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

-- ===== 11回目:運営(マスター)の観戦(不正対策) =====
-- ログイン中のプレイヤーは、フレンドの観戦の設定とは別に、運営だけが入れる観戦の部屋を開く。
-- 部屋の名前は「運営観戦の鍵」から作り、鍵は本人と運営(マスター)にしか返さない
create table if not exists public.audit_keys (
  user_id uuid primary key references auth.users on delete cascade,
  audit_key text not null
);
alter table public.audit_keys enable row level security;

-- 自分の運営観戦の鍵(なければ作る)
create or replace function public.audit_me() returns text
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); k text;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  insert into public.audit_keys (user_id, audit_key) values (me, public.friend_rand(20)) on conflict (user_id) do nothing;
  select audit_key into k from public.audit_keys where user_id = me;
  return k;
end $$;

-- 呼んだ人がマスターか(ログイン中のメールアドレスの SHA-256 で確かめる。index.html の MASTER_HASHES と同じ)
create or replace function public.is_master() returns boolean
  language sql stable security definer set search_path = '' as
  $$ select coalesce(encode(pg_catalog.sha256(convert_to(lower(trim(auth.jwt() ->> 'email')), 'UTF8')), 'hex')
       = any (array['6bc4a36350f6ff8d567a477610dca5984216523e41ce0a92245a24c207916900']), false) $$;

-- ログイン中のプレイヤーの一覧と、運営観戦の鍵(マスターだけ)
create or replace function public.audit_list() returns table (id uuid, name text, st jsonb, seen_at timestamptz, key text)
  language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_master() then raise exception '権限がありません'; end if;
  return query
    select s.user_id, p.name, s.st, s.seen_at, k.audit_key
    from public.user_status s
    join public.profiles p on p.id = s.user_id
    left join public.audit_keys k on k.user_id = s.user_id
    where s.seen_at > now() - interval '3 minutes' and s.user_id <> auth.uid()
    order by s.seen_at desc
    limit 200;
end $$;

revoke execute on function public.audit_me() from public, anon;
revoke execute on function public.is_master() from public, anon;
revoke execute on function public.audit_list() from public, anon;
grant execute on function public.audit_me() to authenticated;
grant execute on function public.is_master() to authenticated;
grant execute on function public.audit_list() to authenticated;

-- ===== 12回目:古い版で遊び続けさせない(ランク戦の相手探しと、レートの開始を断る) =====
-- 最低の版。上げるときは: update public.app_config set v = '1.05' where k = 'min_ver';
create table if not exists public.app_config (k text primary key, v text not null);
alter table public.app_config enable row level security;
insert into public.app_config (k, v) values ('min_ver', '0.99') on conflict (k) do update set v = excluded.v;

-- 版が古ければ、エラー KV001 で断る
create or replace function public.ver_check(p_ver text) returns void
  language plpgsql stable security definer set search_path = '' as $$
declare mv text;
begin
  select v into mv from public.app_config where k = 'min_ver';
  if mv is null then return; end if;
  if p_ver is null or p_ver !~ '^\d+\.\d+$' or p_ver::numeric < mv::numeric then
    raise exception '古い版です。ページを読み込み直してください' using errcode = 'KV001';
  end if;
end $$;

-- レートの開始(版つき)。中身は7回目と同じ
create or replace function public.rate_start(p_key text, p_foe uuid, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  x uuid; y uuid; m public.matches; is_a boolean;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_foe is null or p_foe = me then raise exception '相手が正しくありません'; end if;
  x := least(me, p_foe); y := greatest(me, p_foe); is_a := (me = x);
  if not exists (select 1 from public.matches where a = x and b = y and key = p_key)
     and (select count(*) from public.matches where a = x and b = y and a_started and b_started and created_at > now() - interval '1 day') >= 5 then
    raise exception '同じ相手とのレート戦は1日5回までです' using errcode = 'KS001';
  end if;
  insert into public.matches (key, a, b, a_base, b_base)
    select p_key, x, y, pa.rating, pb.rating from public.profiles pa, public.profiles pb where pa.id = x and pb.id = y
    on conflict do nothing;
  select * into m from public.matches where a = x and b = y and key = p_key for update;
  if not found then raise exception '相手のアカウントが見つかりません'; end if;
  if m.created_at < now() - interval '10 minutes' then raise exception 'この対戦には、もう参加できません'; end if;
  if is_a and not m.a_started then
    update public.matches set a_started = true, a_applied = 0 where a = x and b = y and key = p_key;
    perform public.rate_apply(me, m.a_base, m.b_base, null, 0);
  elsif not is_a and not m.b_started then
    update public.matches set b_started = true, b_applied = 0 where a = x and b = y and key = p_key;
    perform public.rate_apply(me, m.b_base, m.a_base, null, 0);
  end if;
  return (select json_build_object('rating', rating, 'wins', wins, 'losses', losses) from public.profiles where id = me);
end $$;
-- 版を送らない古い版からの呼び出しは断る
create or replace function public.rate_start(p_key text, p_foe uuid) returns json
  language plpgsql security definer set search_path = '' as $$
begin
  raise exception '古い版です。ページを読み込み直してください' using errcode = 'KV001';
end $$;

-- ランク戦の相手探し(版つき)。中身は10回目と同じ
create or replace function public.rank_find(p_ver text) returns text
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); r int; mine public.rank_queue; f public.rank_queue; c text;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  select rating into r from public.profiles where id = me;
  if r is null then raise exception 'プロフィールがありません'; end if;
  perform pg_advisory_xact_lock(7262010);
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
create or replace function public.rank_find() returns text
  language plpgsql security definer set search_path = '' as $$
begin
  raise exception '古い版です。ページを読み込み直してください' using errcode = 'KV001';
end $$;

revoke execute on function public.ver_check(text) from public, anon;
revoke execute on function public.rate_start(text, uuid, text) from public, anon;
revoke execute on function public.rank_find(text) from public, anon;
grant execute on function public.ver_check(text) to authenticated;
grant execute on function public.rate_start(text, uuid, text) to authenticated;
grant execute on function public.rank_find(text) to authenticated;

-- ===== 13回目:刻練場(百刻スコアアタック)の記録とランキング =====
-- 1人1行:最高撃破数・突破した最高の層・累計撃破数・挑戦回数
create table if not exists public.kr_scores (
  user_id uuid primary key references auth.users on delete cascade,
  best_kills int not null default 0,
  best_layers int not null default 0,
  total_kills int not null default 0,
  runs int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.kr_scores enable row level security;
-- 1回の挑戦。始めた時刻を記録し、終わりの報告と突き合わせる(短すぎる時間での大量撃破を断る)
create table if not exists public.kr_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  started_at timestamptz not null default now(),
  done boolean not null default false
);
alter table public.kr_runs enable row level security;

-- 挑戦を始める(古い挑戦の記録は消す)
create or replace function public.kr_start(p_ver text) returns uuid
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); rid uuid;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  delete from public.kr_runs where user_id = me and started_at < now() - interval '1 day';
  insert into public.kr_runs (user_id) values (me) returning id into rid;
  return rid;
end $$;

-- 挑戦の結果を記録する。1体倒すのに最低2秒はかかるものとして、早すぎる報告は断る
create or replace function public.kr_finish(p_run uuid, p_kills int, p_layers int, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); r public.kr_runs; s public.kr_scores;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into r from public.kr_runs where id = p_run and user_id = me for update;
  if not found or r.done then raise exception 'この挑戦は記録できません' using errcode = 'KR001'; end if;
  if p_kills is null or p_kills < 0 or p_kills > 1000 or p_layers is null or p_layers < 0 or p_layers > p_kills then
    raise exception '記録が正しくありません' using errcode = 'KR002';
  end if;
  if extract(epoch from (now() - r.started_at)) < p_kills * 2 then
    raise exception '記録が正しくありません' using errcode = 'KR002';
  end if;
  update public.kr_runs set done = true where id = p_run;
  insert into public.kr_scores (user_id, best_kills, best_layers, total_kills, runs)
    values (me, p_kills, p_layers, p_kills, 1)
    on conflict (user_id) do update set
      best_kills = greatest(public.kr_scores.best_kills, excluded.best_kills),
      best_layers = greatest(public.kr_scores.best_layers, excluded.best_layers),
      total_kills = public.kr_scores.total_kills + excluded.total_kills,
      runs = public.kr_scores.runs + 1,
      updated_at = case when excluded.best_kills > public.kr_scores.best_kills then now() else public.kr_scores.updated_at end
    returning * into s;
  return json_build_object('best_kills', s.best_kills, 'best_layers', s.best_layers, 'total_kills', s.total_kills, 'runs', s.runs);
end $$;

-- ランキング(最高撃破数の上位50人。同じ数なら先に出した人が上)。だれでも見られる
create or replace function public.kr_ranking() returns table (id uuid, name text, title text, fav text, best_kills int, best_layers int, total_kills int)
  language sql stable security definer set search_path = '' as
  $$ select s.user_id, p.name, p.title, p.fav, s.best_kills, s.best_layers, s.total_kills
     from public.kr_scores s join public.profiles p on p.id = s.user_id
     where s.best_kills > 0
     order by s.best_kills desc, s.best_layers desc, s.updated_at asc
     limit 50 $$;

-- 自分の記録
create or replace function public.kr_me() returns json
  language sql stable security definer set search_path = '' as
  $$ select coalesce((select json_build_object('best_kills', best_kills, 'best_layers', best_layers, 'total_kills', total_kills, 'runs', runs) from public.kr_scores where user_id = auth.uid()), '{}'::json) $$;

revoke execute on function public.kr_start(text) from public, anon;
revoke execute on function public.kr_finish(uuid, int, int, text) from public, anon;
revoke execute on function public.kr_me() from public, anon;
grant execute on function public.kr_start(text) to authenticated;
grant execute on function public.kr_finish(uuid, int, int, text) to authenticated;
grant execute on function public.kr_me() to authenticated;
grant execute on function public.kr_ranking() to anon, authenticated;
-- ===== 15回目:ログインボーナスとデイリーミッション =====
-- 日付は日本時間の朝4時で切り替わる。報酬(空間のカケラ)の数はサーバーが決め、端末はそれを所持数に足す
create table if not exists public.daily_state (
  user_id uuid primary key references auth.users on delete cascade,
  login_day date,
  login_streak int not null default 0,
  mission_day date,
  battles int not null default 0,
  kr int not null default 0,
  gacha int not null default 0,
  got int not null default 0   -- 受け取った報酬(1:対戦3回 2:刻練場 4:ガチャ 8:すべて達成)
);
alter table public.daily_state enable row level security;

-- ゲーム内の「今日」(日本時間の朝4時で切り替わる)
create or replace function public.game_day() returns date
  language sql stable set search_path = '' as
  $$ select ((now() at time zone 'Asia/Tokyo') - interval '4 hours')::date $$;

-- ログインボーナス:7日連続で1周(30・30・50・30・30・50・150)。1日空くと1日目に戻る。1日1回だけ
create or replace function public.daily_login(p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); d date := public.game_day(); r public.daily_state; s int; n int;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  insert into public.daily_state (user_id) values (me) on conflict (user_id) do nothing;
  select * into r from public.daily_state where user_id = me for update;
  if r.login_day = d then return json_build_object('streak', r.login_streak, 'shards', 0); end if;
  s := case when r.login_day = d - 1 then r.login_streak % 7 + 1 else 1 end;
  n := (array[30, 30, 50, 30, 30, 50, 150])[s];
  update public.daily_state set login_day = d, login_streak = s where user_id = me;
  return json_build_object('streak', s, 'shards', n);
end $$;

-- デイリーミッションの進み具合を1つ進め、新しく達成した分の報酬を返す
-- battle:対戦が1回終わった / kr:刻練場が1回終わった(対戦1回にも数える) / gacha:ガチャを引いた
create or replace function public.daily_progress(p_kind text, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); d date := public.game_day(); r public.daily_state; g int; add int := 0; done text[] := '{}';
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_kind not in ('battle', 'kr', 'gacha') then raise exception '種類が正しくありません'; end if;
  insert into public.daily_state (user_id) values (me) on conflict (user_id) do nothing;
  select * into r from public.daily_state where user_id = me for update;
  if r.mission_day is distinct from d then r.battles := 0; r.kr := 0; r.gacha := 0; r.got := 0; end if;
  if p_kind in ('battle', 'kr') then r.battles := least(r.battles + 1, 99); end if;
  if p_kind = 'kr' then r.kr := least(r.kr + 1, 99); end if;
  if p_kind = 'gacha' then r.gacha := least(r.gacha + 1, 99); end if;
  g := r.got;
  if r.battles >= 3 and g & 1 = 0 then g := g | 1; add := add + 20; done := done || '対戦3回'::text; end if;
  if r.kr >= 1 and g & 2 = 0 then g := g | 2; add := add + 20; done := done || '刻練場1回'::text; end if;
  if r.gacha >= 1 and g & 4 = 0 then g := g | 4; add := add + 20; done := done || 'お試しガチャ'::text; end if;
  if g & 7 = 7 and g & 8 = 0 then g := g | 8; add := add + 40; done := done || 'すべて達成'::text; end if;
  update public.daily_state set mission_day = d, battles = r.battles, kr = r.kr, gacha = r.gacha, got = g where user_id = me;
  return json_build_object('shards', add, 'done', done, 'battles', r.battles, 'kr', r.kr, 'gacha', r.gacha, 'got', g);
end $$;

-- 自分の今日の進み具合(メールボックスに出す)
create or replace function public.daily_me() returns json
  language sql stable security definer set search_path = '' as $$
  select coalesce((
    select json_build_object(
      'streak', case when login_day >= public.game_day() - 1 then login_streak else 0 end,
      'battles', case when mission_day = public.game_day() then battles else 0 end,
      'kr', case when mission_day = public.game_day() then kr else 0 end,
      'gacha', case when mission_day = public.game_day() then gacha else 0 end,
      'got', case when mission_day = public.game_day() then got else 0 end)
    from public.daily_state where user_id = auth.uid()),
    json_build_object('streak', 0, 'battles', 0, 'kr', 0, 'gacha', 0, 'got', 0)) $$;

revoke execute on function public.daily_login(text) from public, anon;
revoke execute on function public.daily_progress(text, text) from public, anon;
revoke execute on function public.daily_me() from public, anon;
grant execute on function public.daily_login(text) to authenticated;
grant execute on function public.daily_progress(text, text) to authenticated;
grant execute on function public.daily_me() to authenticated;
-- ===== 16回目:空間のカケラと持っているキャラを、サーバーだけが書き換える =====
-- これまでは progress の stats(本人が丸ごと書き換えられる)に、カケラ(shards)と持っているキャラ(owned)を置いていた。
-- ここからは wallet 表に移し、増やす・減らすのはサーバーの関数だけにする。ガチャの抽選もサーバーで行う。
-- 今あるカケラとキャラ・受け取り済みの記録は、そのまま引き継ぐ。

create table if not exists public.wallet (
  user_id uuid primary key references auth.users on delete cascade,
  shards int not null default 0 check (shards >= 0),
  owned jsonb not null default '{}',              -- { キャラID: 枚数 }
  mail_got text[] not null default '{}',          -- 受け取ったメールのプレゼント
  invite_got uuid[] not null default '{}',        -- 招待ボーナスを受け取った相手(招待した側)
  invite_used boolean not null default false,     -- 招待コードを使ったボーナスを受け取ったか(招待された側)
  master_grant boolean not null default false,    -- マスターの初回補充を受け取ったか
  solo_first text[] not null default '{}',        -- 初回クリア報酬を受け取った回廊のステージ
  free_day date, free_got int not null default 0, -- フリー戦でその日に受け取ったカケラ(1日200まで)
  updated_at timestamptz not null default now()
);
alter table public.wallet enable row level security;
drop policy if exists "財布:自分だけ見られる" on public.wallet;
create policy "財布:自分だけ見られる" on public.wallet for select using (auth.uid() = user_id);
revoke insert, update, delete on public.wallet from anon, authenticated;

-- 今の記録を引き継ぐ(すでに財布がある人はそのまま)
insert into public.wallet (user_id, shards, owned, mail_got, invite_got, invite_used, master_grant, solo_first)
select g.id,
  case when (g.stats ->> 'shards') ~ '^[0-9]{1,9}$' then (g.stats ->> 'shards')::int else 0 end,
  case when jsonb_typeof(g.stats -> 'owned') = 'object' then g.stats -> 'owned' else '{}'::jsonb end,
  case when jsonb_typeof(g.stats -> 'mailGot') = 'array' then array(select jsonb_array_elements_text(g.stats -> 'mailGot')) else '{}'::text[] end,
  case when jsonb_typeof(g.stats -> 'inviteGot') = 'array'
    then array(select x::uuid from jsonb_array_elements_text(g.stats -> 'inviteGot') x where x ~ '^[0-9a-f-]{36}$') else '{}'::uuid[] end,
  coalesce(g.stats ? 'inviteUsed', false),
  coalesce((g.stats ->> 'masterGrant1') = '1', false),
  array(select s from unnest(g.cleared) s where s ~ '^r[0-9]_[45]$')
from public.progress g
on conflict (user_id) do nothing;

-- 財布にカケラを足す(サーバーの関数の中だけで使う。外からは呼べない)
create or replace function public.wallet_add(u uuid, n int) returns int
  language plpgsql security definer set search_path = '' as $$
declare t int;
begin
  insert into public.wallet (user_id) values (u) on conflict (user_id) do nothing;
  update public.wallet set shards = shards + n, updated_at = now() where user_id = u returning shards into t;
  return t;
end $$;
revoke execute on function public.wallet_add(uuid, int) from public, anon, authenticated;

-- 自分の財布(なければ空で作る)
create or replace function public.wallet_me() returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); w public.wallet;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me;
  return json_build_object('shards', w.shards, 'owned', w.owned, 'mail_got', w.mail_got,
    'free_got', case when w.free_day = public.game_day() then w.free_got else 0 end);
end $$;

-- ===== ガチャ:サーバーで抽選する(1回25個・11回250個) =====
-- 確率:★5 0.1% / ★4 1% / ★3 30% / ★2 30.9% / ★1 38%。同じ★の中は等分(index.html の GACHA_RATES と同じ)
create or replace function public.gacha_pull(p_times int, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid(); cost int; w public.wallet; r float8; pool text[]; id text; o jsonb;
  ids text[] := '{}'; fresh boolean[] := '{}'; i int;
  s5 text[] := array['g_z5'];
  s4 text[] := array['g_a4', 'g_z4', 'g_y4'];
  s3 text[] := array['g_a3a', 'g_a3b', 'g_a3c', 'g_z3a', 'g_z3b', 'g_z3c', 'g_y3a', 'g_y3b', 'g_y3c'];
  s2 text[] := array['g_a2', 'g_z2', 'g_y2'];
  s1 text[] := array['g_a1', 'g_z1', 'g_y1'];
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_times = 1 then cost := 25; elsif p_times = 11 then cost := 250; else raise exception '回数が正しくありません'; end if;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me for update;
  if w.shards < cost then raise exception '空間のカケラが足りません' using errcode = 'GC001'; end if;
  o := w.owned;
  for i in 1 .. p_times loop
    r := random();
    pool := case when r < 0.001 then s5 when r < 0.011 then s4 when r < 0.311 then s3 when r < 0.62 then s2 else s1 end;
    id := pool[1 + floor(random() * array_length(pool, 1))::int];
    fresh := fresh || (coalesce((o ->> id)::int, 0) = 0);
    o := jsonb_set(o, array[id], to_jsonb(coalesce((o ->> id)::int, 0) + 1));
    ids := ids || id;
  end loop;
  update public.wallet set shards = shards - cost, owned = o, updated_at = now() where user_id = me;
  return json_build_object('ids', ids, 'fresh', fresh, 'shards', w.shards - cost, 'owned', o);
end $$;

-- ===== メールのプレゼント =====
-- プレゼントの中身はここに登録する(index.html の MAILS と同じ id)。until を過ぎたら受け取れない(日本時間の朝4時区切り)
create table if not exists public.mail_gifts (
  id text primary key,
  shards int not null default 0,
  chars text[] not null default '{}',
  until date
);
alter table public.mail_gifts enable row level security;
revoke all on public.mail_gifts from anon, authenticated;
insert into public.mail_gifts (id, shards) values ('m001', 400), ('m002', 550), ('m003', 250) on conflict (id) do nothing;

create or replace function public.mail_claim(p_ids text[], p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); w public.wallet; m public.mail_gifts; add int := 0; got text[] := '{}'; o jsonb; c text;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me for update;
  o := w.owned;
  for m in select * from public.mail_gifts where id = any (p_ids) and not (id = any (w.mail_got)) and (until is null or until >= public.game_day()) loop
    add := add + m.shards;
    foreach c in array m.chars loop o := jsonb_set(o, array[c], to_jsonb(coalesce((o ->> c)::int, 0) + 1)); end loop;
    got := got || m.id;
  end loop;
  update public.wallet set shards = shards + add, owned = o, mail_got = mail_got || got, updated_at = now() where user_id = me;
  return json_build_object('got', got, 'given', add, 'shards', w.shards + add, 'owned', o, 'mail_got', w.mail_got || got);
end $$;

-- ===== オンライン対人の報酬 =====
-- フリー戦:勝ち20・負け5。日本時間の朝4時区切りで1日200個まで
-- ランク戦:勝ち30。レートの記録(rate_start)がある対戦だけ。3本勝負なので1つの対戦で2勝ぶんまで
create table if not exists public.rank_rewards (
  user_id uuid not null references auth.users on delete cascade,
  key text not null,
  n int not null default 0,
  primary key (user_id, key)
);
alter table public.rank_rewards enable row level security;
revoke all on public.rank_rewards from anon, authenticated;

create or replace function public.pvp_reward(p_rank boolean, p_win boolean, p_key text, p_foe uuid, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); d date := public.game_day(); w public.wallet; base int; give int := 0; got int; x uuid; y uuid; k int;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me for update;
  if not coalesce(p_rank, false) then
    base := case when p_win then 20 else 5 end;
    got := case when w.free_day = d then w.free_got else 0 end;
    give := greatest(0, least(base, 200 - got));
    update public.wallet set shards = shards + give, free_day = d, free_got = got + give, updated_at = now() where user_id = me;
    return json_build_object('given', give, 'shards', w.shards + give, 'free_got', got + give, 'capped', give < base);
  end if;
  if not p_win or p_foe is null then return json_build_object('given', 0, 'shards', w.shards); end if;
  x := least(me, p_foe); y := greatest(me, p_foe);
  if not exists (select 1 from public.matches where a = x and b = y and key = p_key
                 and (case when me = x then a_started else b_started end) and created_at > now() - interval '3 hours') then
    return json_build_object('given', 0, 'shards', w.shards);
  end if;
  insert into public.rank_rewards (user_id, key) values (me, p_key) on conflict do nothing;
  select n into k from public.rank_rewards where user_id = me and key = p_key for update;
  if k >= 2 then return json_build_object('given', 0, 'shards', w.shards); end if;
  update public.rank_rewards set n = n + 1 where user_id = me and key = p_key;
  update public.wallet set shards = shards + 30, updated_at = now() where user_id = me;
  return json_build_object('given', 30, 'shards', w.shards + 30);
end $$;

-- ===== 刻の回廊の★4・★5のクリア報酬 =====
-- 挑戦を始めたら solo_start、勝ったら solo_reward。始めてから45秒たたない報告は断る。初回は多め
create table if not exists public.solo_rewards (stage text primary key, first int not null, again int not null);
alter table public.solo_rewards enable row level security;
revoke all on public.solo_rewards from anon, authenticated;
insert into public.solo_rewards (stage, first, again) values
  ('r1_4', 200, 20), ('r2_4', 200, 20), ('r3_4', 200, 20), ('r4_4', 200, 20),
  ('r1_5', 1000, 40), ('r2_5', 1000, 40), ('r3_5', 1000, 40), ('r4_5', 1000, 40)
  on conflict (stage) do update set first = excluded.first, again = excluded.again;

create table if not exists public.solo_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  stage text not null,
  started_at timestamptz not null default now(),
  done boolean not null default false
);
alter table public.solo_runs enable row level security;
revoke all on public.solo_runs from anon, authenticated;

create or replace function public.solo_start(p_stage text, p_ver text) returns uuid
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); rid uuid;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  if not exists (select 1 from public.solo_rewards where stage = p_stage) then return null; end if;
  delete from public.solo_runs where user_id = me and started_at < now() - interval '1 day';
  insert into public.solo_runs (user_id, stage) values (me, p_stage) returning id into rid;
  return rid;
end $$;

create or replace function public.solo_reward(p_run uuid, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); r public.solo_runs; rw public.solo_rewards; w public.wallet; first boolean; give int;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into r from public.solo_runs where id = p_run and user_id = me for update;
  if not found or r.done then raise exception 'この挑戦は記録できません' using errcode = 'SR001'; end if;
  if r.started_at > now() - interval '45 seconds' then raise exception '記録が正しくありません' using errcode = 'SR002'; end if;
  select * into rw from public.solo_rewards where stage = r.stage;
  update public.solo_runs set done = true where id = p_run;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me for update;
  first := not (r.stage = any (w.solo_first));
  give := case when first then rw.first else rw.again end;
  update public.wallet set shards = shards + give, solo_first = case when first then solo_first || r.stage else solo_first end, updated_at = now()
    where user_id = me;
  return json_build_object('given', give, 'first', first, 'shards', w.shards + give);
end $$;

-- ===== はじめてのフレンド(200個)・招待(お互いに700個)・マスターの補充 =====
create or replace function public.friend_reward() returns boolean
  language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  if public.friend_count(auth.uid()) < 1 then return false; end if;
  insert into public.friend_rewards (user_id) values (auth.uid()) on conflict do nothing;
  if found then perform public.wallet_add(auth.uid(), 200); return true; end if;
  return false;
end $$;

-- 招待した側:新しく招待コードを使った人の分を受け取る(5人まで)
create or replace function public.invite_collect(p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); w public.wallet; fresh uuid[];
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me for update;
  fresh := array(select invitee from public.invites where inviter = me and not (invitee = any (w.invite_got))
                 order by created_at limit greatest(0, 5 - coalesce(array_length(w.invite_got, 1), 0)));
  if coalesce(array_length(fresh, 1), 0) = 0 then return json_build_object('n', 0, 'shards', w.shards); end if;
  update public.wallet set shards = shards + 700 * array_length(fresh, 1), invite_got = invite_got || fresh, updated_at = now() where user_id = me;
  return json_build_object('n', array_length(fresh, 1), 'shards', w.shards + 700 * array_length(fresh, 1));
end $$;

-- 招待された側:招待コードを使ったら1回だけ受け取る
create or replace function public.invite_self(p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); w public.wallet;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me for update;
  if w.invite_used or not exists (select 1 from public.invites where invitee = me) then return json_build_object('given', 0, 'shards', w.shards); end if;
  update public.wallet set shards = shards + 700, invite_used = true, updated_at = now() where user_id = me;
  return json_build_object('given', 700, 'shards', w.shards + 700);
end $$;

-- マスターだけ:p_once なら初回の10000個(1回だけ)、そうでなければテスト用に3000個
create or replace function public.master_grant(p_once boolean) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); w public.wallet;
begin
  if me is null or not coalesce(public.is_master(), false) then raise exception '権限がありません'; end if;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me for update;
  if p_once and w.master_grant then return json_build_object('given', 0, 'shards', w.shards); end if;
  update public.wallet set shards = shards + case when p_once then 10000 else 3000 end,
    master_grant = master_grant or p_once, updated_at = now() where user_id = me;
  return json_build_object('given', case when p_once then 10000 else 3000 end, 'shards', w.shards + case when p_once then 10000 else 3000 end);
end $$;

-- ===== ログインボーナス・デイリーミッション(15回目)を、財布に直接入れる形にする =====
create or replace function public.daily_login(p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); d date := public.game_day(); r public.daily_state; s int; n int; t int;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  insert into public.daily_state (user_id) values (me) on conflict (user_id) do nothing;
  select * into r from public.daily_state where user_id = me for update;
  if r.login_day = d then return json_build_object('streak', r.login_streak, 'shards', 0); end if;
  s := case when r.login_day = d - 1 then r.login_streak % 7 + 1 else 1 end;
  n := (array[30, 30, 50, 30, 30, 50, 150])[s];
  update public.daily_state set login_day = d, login_streak = s where user_id = me;
  t := public.wallet_add(me, n);
  return json_build_object('streak', s, 'shards', n, 'total', t);
end $$;

create or replace function public.daily_progress(p_kind text, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); d date := public.game_day(); r public.daily_state; g int; add int := 0; done text[] := '{}'; t int;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_kind not in ('battle', 'kr', 'gacha') then raise exception '種類が正しくありません'; end if;
  insert into public.daily_state (user_id) values (me) on conflict (user_id) do nothing;
  select * into r from public.daily_state where user_id = me for update;
  if r.mission_day is distinct from d then r.battles := 0; r.kr := 0; r.gacha := 0; r.got := 0; end if;
  if p_kind in ('battle', 'kr') then r.battles := least(r.battles + 1, 99); end if;
  if p_kind = 'kr' then r.kr := least(r.kr + 1, 99); end if;
  if p_kind = 'gacha' then r.gacha := least(r.gacha + 1, 99); end if;
  g := r.got;
  if r.battles >= 3 and g & 1 = 0 then g := g | 1; add := add + 20; done := done || '対戦3回'::text; end if;
  if r.kr >= 1 and g & 2 = 0 then g := g | 2; add := add + 20; done := done || '刻練場1回'::text; end if;
  if r.gacha >= 1 and g & 4 = 0 then g := g | 4; add := add + 20; done := done || 'お試しガチャ'::text; end if;
  if g & 7 = 7 and g & 8 = 0 then g := g | 8; add := add + 40; done := done || 'すべて達成'::text; end if;
  update public.daily_state set mission_day = d, battles = r.battles, kr = r.kr, gacha = r.gacha, got = g where user_id = me;
  t := case when add > 0 then public.wallet_add(me, add) else null end;
  return json_build_object('shards', add, 'done', done, 'battles', r.battles, 'kr', r.kr, 'gacha', r.gacha, 'got', g, 'total', t);
end $$;

revoke execute on function public.wallet_me() from public, anon;
revoke execute on function public.gacha_pull(int, text) from public, anon;
revoke execute on function public.mail_claim(text[], text) from public, anon;
revoke execute on function public.pvp_reward(boolean, boolean, text, uuid, text) from public, anon;
revoke execute on function public.solo_start(text, text) from public, anon;
revoke execute on function public.solo_reward(uuid, text) from public, anon;
revoke execute on function public.invite_collect(text) from public, anon;
revoke execute on function public.invite_self(text) from public, anon;
revoke execute on function public.master_grant(boolean) from public, anon;
grant execute on function public.wallet_me() to authenticated;
grant execute on function public.gacha_pull(int, text) to authenticated;
grant execute on function public.mail_claim(text[], text) to authenticated;
grant execute on function public.pvp_reward(boolean, boolean, text, uuid, text) to authenticated;
grant execute on function public.solo_start(text, text) to authenticated;
grant execute on function public.solo_reward(uuid, text) to authenticated;
grant execute on function public.invite_collect(text) to authenticated;
grant execute on function public.invite_self(text) to authenticated;
grant execute on function public.master_grant(boolean) to authenticated;
-- ===== 17回目:キャラが使えるようになる称号を、サーバーが判定して記録する =====
-- これまでは、条件を満たしたかを端末が判定して profiles.titles(本人が書き換えられる)に書いていた。
-- キャラの解放に関わる称号だけ、サーバーの unlocks 表に記録する(本人は読むだけ)。
--   刻練場の記録から判定:kr300・kr500・kr1000・krUtsuro(累計撃破)、kr32・kr36・kr40(突破した層)
--   ソロのクリアから判定:tengan(天眼の果て)・shiToki(トキバミで始まり)・kaji(カジで始まりの前/ボスラッシュ)・
--                        rush5(ボスラッシュ)・trio(カジ・レイ・ツルでトキバミ)
-- いま持っている称号は、そのまま引き継ぐ。

create table if not exists public.unlocks (
  user_id uuid not null references auth.users on delete cascade,
  id text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, id)
);
alter table public.unlocks enable row level security;
drop policy if exists "解放:自分だけ見られる" on public.unlocks;
create policy "解放:自分だけ見られる" on public.unlocks for select using (auth.uid() = user_id);
revoke insert, update, delete on public.unlocks from anon, authenticated;

-- 今の称号を引き継ぐ
insert into public.unlocks (user_id, id)
select p.id, t from public.profiles p, unnest(coalesce(p.titles, '{}')) t
where t in ('kr300', 'kr500', 'kr1000', 'krUtsuro', 'kr32', 'kr36', 'kr40', 'tengan', 'shiToki', 'kaji', 'rush5', 'trio')
on conflict do nothing;

-- ソロのステージをクリアすると解放される称号。need はパーティに入っていないといけないキャラ(全員)
create table if not exists public.unlock_stages (
  stage text not null,
  title text not null,
  need text[] not null default '{}',
  primary key (stage, title)
);
alter table public.unlock_stages enable row level security;
revoke all on public.unlock_stages from anon, authenticated;
insert into public.unlock_stages (stage, title, need) values
  ('r4_5', 'tengan', '{}'),
  ('k5', 'shiToki', '{p_tokibami}'),
  ('x5', 'kaji', '{kaji}'),
  ('rush', 'kaji', '{kaji}'),
  ('rush', 'rush5', '{}'),
  ('t4', 'trio', '{kaji,rei,tsuru}')
  on conflict (stage, title) do update set need = excluded.need;

alter table public.solo_runs add column if not exists party text[] not null default '{}';

-- 刻練場の記録から判定する(ログインしたとき・刻練場を遊んだあとに呼ぶ)。戻り値は、解放済みの称号の一覧
create or replace function public.unlock_sync(p_ver text) returns text[]
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); s public.kr_scores;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into s from public.kr_scores where user_id = me;
  if found then
    insert into public.unlocks (user_id, id)
    select me, t from (values
      ('kr300', s.total_kills >= 300), ('kr500', s.total_kills >= 500), ('kr1000', s.total_kills >= 1000), ('krUtsuro', s.total_kills >= 2000),
      ('kr32', s.best_layers >= 8), ('kr36', s.best_layers >= 9), ('kr40', s.best_layers >= 10)) v(t, ok)
    where ok on conflict do nothing;
  end if;
  return array(select id from public.unlocks where user_id = me order by created_at);
end $$;

-- ソロの挑戦の開始(報酬のあるステージ・称号が解放されるステージ)。パーティも記録する
create or replace function public.solo_start(p_stage text, p_party text[], p_ver text) returns uuid
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); rid uuid;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  if not exists (select 1 from public.solo_rewards where stage = p_stage)
     and not exists (select 1 from public.unlock_stages where stage = p_stage) then return null; end if;
  delete from public.solo_runs where user_id = me and started_at < now() - interval '1 day';
  insert into public.solo_runs (user_id, stage, party) values (me, p_stage, coalesce(p_party, '{}')) returning id into rid;
  return rid;
end $$;

-- 勝ったときの報告:カケラの報酬(あれば)と、解放される称号(あれば)。始めてから45秒たたない報告は断る
create or replace function public.solo_reward(p_run uuid, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); r public.solo_runs; rw public.solo_rewards; w public.wallet; first boolean := false; give int := 0; got text[];
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into r from public.solo_runs where id = p_run and user_id = me for update;
  if not found or r.done then raise exception 'この挑戦は記録できません' using errcode = 'SR001'; end if;
  if r.started_at > now() - interval '45 seconds' then raise exception '記録が正しくありません' using errcode = 'SR002'; end if;
  update public.solo_runs set done = true where id = p_run;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me for update;
  select * into rw from public.solo_rewards where stage = r.stage;
  if found then
    first := not (r.stage = any (w.solo_first));
    give := case when first then rw.first else rw.again end;
    update public.wallet set shards = shards + give, solo_first = case when first then solo_first || r.stage else solo_first end, updated_at = now()
      where user_id = me;
  end if;
  with ins as (
    insert into public.unlocks (user_id, id)
    select me, u.title from public.unlock_stages u where u.stage = r.stage and u.need <@ r.party
    on conflict do nothing returning id)
  select coalesce(array_agg(id), '{}') into got from ins;
  return json_build_object('given', give, 'first', first, 'shards', w.shards + give, 'unlocked', got);
end $$;

revoke execute on function public.unlock_sync(text) from public, anon;
revoke execute on function public.solo_start(text, text[], text) from public, anon;
grant execute on function public.unlock_sync(text) to authenticated;
grant execute on function public.solo_start(text, text[], text) to authenticated;

-- ===== 18回目:利用状況(運営だけが見られる数字) =====
-- ゲーム内の「利用状況(運営)」の画面に出す数字をまとめて返す。マスター以外が呼ぶとエラーになる。
-- ※通信量(Egress)はここでは分からない。Supabase の Usage の画面で見る
create or replace function public.admin_stats() returns json
  language plpgsql security definer set search_path = '' as $$
declare
  db_bytes bigint; tables json; days json; r json;
begin
  if auth.uid() is null or not coalesce(public.is_master(), false) then raise exception '権限がありません'; end if;
  db_bytes := pg_catalog.pg_database_size(pg_catalog.current_database());
  -- 大きい表の上位6つ(どの記録が増えているかを見る)
  select coalesce(json_agg(t), '[]'::json) into tables from (
    select c.relname as name, pg_catalog.pg_total_relation_size(c.oid) as bytes, greatest(c.reltuples, 0)::bigint as est_rows
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
    order by pg_catalog.pg_total_relation_size(c.oid) desc limit 6) t;
  -- 直近7日の、日ごとの新しいアカウントの数(日本時間)
  select coalesce(json_agg(d order by d.day), '[]'::json) into days from (
    select to_char(g.day, 'MM/DD') as day,
           (select count(*) from auth.users u where (u.created_at at time zone 'Asia/Tokyo')::date = g.day) as n
    from (select ((now() at time zone 'Asia/Tokyo')::date - i) as day from generate_series(0, 6) i) g) d;
  select json_build_object(
    'at', now(),
    'db_bytes', db_bytes,
    'db_limit_bytes', 500 * 1024 * 1024,
    'accounts', (select count(*) from auth.users),
    'accounts_24h', (select count(*) from auth.users where created_at > now() - interval '1 day'),
    'accounts_7d', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'online_now', (select count(*) from public.user_status where seen_at > now() - interval '3 minutes'),
    'active_24h', (select count(*) from public.user_status where seen_at > now() - interval '1 day'),
    'active_7d', (select count(*) from public.user_status where seen_at > now() - interval '7 days'),
    'signin_30d', (select count(*) from auth.users where last_sign_in_at > now() - interval '30 days'),
    'rated_24h', (select count(*) from public.matches where a_started and b_started and created_at > now() - interval '1 day'),
    'rated_7d', (select count(*) from public.matches where a_started and b_started and created_at > now() - interval '7 days'),
    'rated_all', (select count(*) from public.matches where a_started and b_started),
    'rated_conflict_7d', (select count(*) from public.matches where a_claim + b_claim > 1 and created_at > now() - interval '7 days'),
    'rank_queue', (select count(*) from public.rank_queue where seen_at > now() - interval '15 seconds'),
    'days', days,
    'tables', tables
  ) into r;
  return r;
end $$;
revoke execute on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;

-- ===== 19回目:降臨クエスト(毎日 12:00〜14:00・18:00〜19:00・21:00〜22:00 だけ挑める) =====
-- ・開いているかは、サーバーの時計(日本時間)で決める。時間外に始めた挑戦は記録しない
-- ・報酬のカケラは、これまでのソロの報酬(solo_rewards)と同じしくみ(初回は多め)
-- ・クリアするたびに、ステージごとの確率でボスのキャラが解放される(抽選もサーバー)

-- ステージごとの解放の抽選(title は unlocks に入る id。chance は 0〜1)
create table if not exists public.quest_drops (
  stage text primary key,
  title text not null,
  chance float8 not null check (chance >= 0 and chance <= 1)
);
alter table public.quest_drops enable row level security;
revoke all on public.quest_drops from anon, authenticated;
insert into public.quest_drops (stage, title, chance) values
  ('qe3', 'emo', 0.002), ('qe4', 'emo', 0.005), ('qe5', 'emo', 0.25),
  ('qr3', 'rizu', 0.002), ('qr4', 'rizu', 0.005), ('qr5', 'rizu', 0.25)
  on conflict (stage) do update set title = excluded.title, chance = excluded.chance;

insert into public.solo_rewards (stage, first, again) values
  ('qe3', 100, 10), ('qe4', 200, 20), ('qe5', 1000, 30),
  ('qr3', 100, 10), ('qr4', 200, 20), ('qr5', 1000, 30)
  on conflict (stage) do update set first = excluded.first, again = excluded.again;

-- 降臨が開いているか(日本時間で 12時台・13時台・18時台・21時台)
create or replace function public.quest_open() returns boolean
  language sql stable set search_path = '' as $$
  select extract(hour from (now() at time zone 'Asia/Tokyo'))::int in (12, 13, 18, 21)
$$;

-- ソロの挑戦の開始:降臨のステージは、開いている時間だけ始められる
create or replace function public.solo_start(p_stage text, p_party text[], p_ver text) returns uuid
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); rid uuid;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  if not exists (select 1 from public.solo_rewards where stage = p_stage)
     and not exists (select 1 from public.unlock_stages where stage = p_stage) then return null; end if;
  if exists (select 1 from public.quest_drops where stage = p_stage) and not public.quest_open() then
    raise exception '降臨の時間外です' using errcode = 'QS001';
  end if;
  delete from public.solo_runs where user_id = me and started_at < now() - interval '1 day';
  insert into public.solo_runs (user_id, stage, party) values (me, p_stage, coalesce(p_party, '{}')) returning id into rid;
  return rid;
end $$;

-- 勝ったときの報告:カケラ・解放される称号に、降臨の抽選を足す
create or replace function public.solo_reward(p_run uuid, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); r public.solo_runs; rw public.solo_rewards; w public.wallet; first boolean := false; give int := 0; got text[]; drop_got text[];
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into r from public.solo_runs where id = p_run and user_id = me for update;
  if not found or r.done then raise exception 'この挑戦は記録できません' using errcode = 'SR001'; end if;
  if r.started_at > now() - interval '45 seconds' then raise exception '記録が正しくありません' using errcode = 'SR002'; end if;
  update public.solo_runs set done = true where id = p_run;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select * into w from public.wallet where user_id = me for update;
  select * into rw from public.solo_rewards where stage = r.stage;
  if found then
    first := not (r.stage = any (w.solo_first));
    give := case when first then rw.first else rw.again end;
    update public.wallet set shards = shards + give, solo_first = case when first then solo_first || r.stage else solo_first end, updated_at = now()
      where user_id = me;
  end if;
  with ins as (
    insert into public.unlocks (user_id, id)
    select me, u.title from public.unlock_stages u where u.stage = r.stage and u.need <@ r.party
    on conflict do nothing returning id)
  select coalesce(array_agg(id), '{}') into got from ins;
  -- 降臨:クリアするたびに抽選。当たって、まだ持っていなければ解放
  with ins2 as (
    insert into public.unlocks (user_id, id)
    select me, q.title from public.quest_drops q where q.stage = r.stage and random() < q.chance
    on conflict do nothing returning id)
  select coalesce(array_agg(id), '{}') into drop_got from ins2;
  return json_build_object('given', give, 'first', first, 'shards', w.shards + give, 'unlocked', got || drop_got);
end $$;

revoke execute on function public.quest_open() from public, anon;
grant execute on function public.quest_open() to authenticated;

-- ===== 20回目:降臨の開催時間を変える(毎日 8:00〜10:00・12:00〜14:00・18:00〜20:00・21:00〜24:00) =====
create or replace function public.quest_open() returns boolean
  language sql stable set search_path = '' as $$
  select extract(hour from (now() at time zone 'Asia/Tokyo'))::int in (8, 9, 12, 13, 18, 19, 21, 22, 23)
$$;

-- ===== 21回目:プレイヤーレベル(経験値)とスタミナ =====
-- ・経験値は profiles.exp(だれでも読めるが、書き換えられるのはこの関数だけ)。レベルは経験値から計算する
--   Lv n → n+1 に必要な経験値 = round(100 × 1.02^(n−1))
-- ・スタミナは wallet(本人だけ見られる)。3分で1回復。最大は 50 + (Lv−1)÷2(切り捨て)
-- ・ソロ・刻の回廊・降臨は、始めるときにスタミナが足りるかを見て、クリアしたときに消費する(負けたら減らない)
-- ・スコアアタック(kr)はスタミナも経験値もなし
-- ・空間のカケラ25で、スタミナを最大値ぶん回復(最大をこえてもよい)

alter table public.profiles add column if not exists exp int not null default 0;
alter table public.wallet add column if not exists stamina int;
alter table public.wallet add column if not exists stamina_at timestamptz;

-- ステージごとの消費スタミナと経験値
create table if not exists public.stage_stamina (
  stage text primary key,
  cost int not null check (cost >= 0),
  exp int not null check (exp >= 0)
);
alter table public.stage_stamina enable row level security;
revoke all on public.stage_stamina from anon, authenticated;
insert into public.stage_stamina (stage, cost, exp) values
  ('a1', 10, 1), ('z1', 10, 1), ('y1', 10, 1),
  ('a2', 10, 1), ('z2', 10, 1), ('y2', 10, 1), ('r1_2', 10, 1), ('r2_2', 10, 1), ('r3_2', 10, 1), ('r4_2', 10, 1),
  ('a3', 20, 20), ('z3', 20, 20), ('y3', 20, 20), ('r1_3', 20, 20), ('r2_3', 20, 20), ('r3_3', 20, 20), ('r4_3', 20, 20), ('qe3', 20, 20), ('qr3', 20, 20),
  ('t4', 20, 100), ('k4', 20, 100), ('r1_4', 20, 100), ('r2_4', 20, 100), ('r3_4', 20, 100), ('r4_4', 20, 100), ('qe4', 20, 100), ('qr4', 20, 100),
  ('x5', 25, 200), ('k5', 25, 200), ('r1_5', 25, 200), ('r2_5', 25, 200), ('r3_5', 25, 200), ('r4_5', 25, 200), ('qe5', 25, 200), ('qr5', 25, 200),
  ('rush', 25, 200)
  on conflict (stage) do update set cost = excluded.cost, exp = excluded.exp;

-- 経験値からレベル
create or replace function public.lv_of(p_exp int) returns int
  language plpgsql immutable set search_path = '' as $$
declare lv int := 1; left_exp bigint := greatest(coalesce(p_exp, 0), 0); need bigint;
begin
  loop
    need := round(100 * power(1.02, lv - 1));
    exit when left_exp < need or lv >= 9999;
    left_exp := left_exp - need; lv := lv + 1;
  end loop;
  return lv;
end $$;
create or replace function public.stamina_max(p_lv int) returns int
  language sql immutable set search_path = '' as $$ select 50 + (greatest(p_lv, 1) - 1) / 2 $$;

-- 今のスタミナ(回復ぶんを足して保存し直す)。行がなければ作る(はじめは最大)
create or replace function public.stamina_sync(me uuid, out val int, out mx int, out next_sec int)
  language plpgsql security definer set search_path = '' as $$
declare s int; a timestamptz; n int; e int;
begin
  select coalesce(p.exp, 0) into e from public.profiles p where p.id = me;
  mx := public.stamina_max(public.lv_of(coalesce(e, 0)));
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  select w.stamina, w.stamina_at into s, a from public.wallet w where w.user_id = me for update;
  if s is null then s := mx; a := now(); end if;
  if s >= mx then
    val := s; a := now(); next_sec := 0;
  else
    n := floor(extract(epoch from (now() - a)) / 180)::int;
    val := least(mx, s + n);
    if val >= mx then a := now(); next_sec := 0;
    else a := a + make_interval(secs => n * 180); next_sec := 180 - floor(extract(epoch from (now() - a)))::int; end if;
  end if;
  update public.wallet set stamina = val, stamina_at = a where user_id = me;
end $$;
revoke execute on function public.stamina_sync(uuid) from public, anon, authenticated;

-- 画面用:スタミナとレベル
create or replace function public.stamina_get() returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); st record; e int;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into st from public.stamina_sync(me);
  select coalesce(exp, 0) into e from public.profiles where id = me;
  return json_build_object('stamina', st.val, 'max', st.mx, 'next_sec', st.next_sec, 'exp', coalesce(e, 0));
end $$;

-- 空間のカケラ25で、最大値ぶん回復
create or replace function public.stamina_refill() returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); st record; w public.wallet;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into st from public.stamina_sync(me);
  select * into w from public.wallet where user_id = me for update;
  if w.shards < 25 then raise exception '空間のカケラが足りません' using errcode = 'ST002'; end if;
  update public.wallet set shards = shards - 25, stamina = st.val + st.mx,
    stamina_at = now(), updated_at = now() where user_id = me;
  return json_build_object('stamina', st.val + st.mx, 'max', st.mx, 'next_sec', 0, 'shards', w.shards - 25);
end $$;

-- ソロの挑戦の開始:降臨は時間内だけ。スタミナのあるステージは、足りるときだけ始められる(ここでは減らさない)
create or replace function public.solo_start(p_stage text, p_party text[], p_ver text) returns uuid
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); rid uuid; c int; st record;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  if not exists (select 1 from public.solo_rewards where stage = p_stage)
     and not exists (select 1 from public.unlock_stages where stage = p_stage)
     and not exists (select 1 from public.stage_stamina where stage = p_stage) then return null; end if;
  if exists (select 1 from public.quest_drops where stage = p_stage) and not public.quest_open() then
    raise exception '降臨の時間外です' using errcode = 'QS001';
  end if;
  select cost into c from public.stage_stamina where stage = p_stage;
  if c is not null and c > 0 then
    select * into st from public.stamina_sync(me);
    if st.val < c then raise exception 'スタミナが足りません' using errcode = 'ST001'; end if;
  end if;
  delete from public.solo_runs where user_id = me and started_at < now() - interval '1 day';
  insert into public.solo_runs (user_id, stage, party) values (me, p_stage, coalesce(p_party, '{}')) returning id into rid;
  return rid;
end $$;

-- 勝ったときの報告:カケラ・称号・降臨の抽選に、スタミナの消費と経験値を足す
create or replace function public.solo_reward(p_run uuid, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); r public.solo_runs; rw public.solo_rewards; w public.wallet; first boolean := false; give int := 0; got text[]; drop_got text[];
  ss public.stage_stamina; st record; left_st int := null; mx int := null; e_now int := null; e_got int := 0;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into r from public.solo_runs where id = p_run and user_id = me for update;
  if not found or r.done then raise exception 'この挑戦は記録できません' using errcode = 'SR001'; end if;
  if r.started_at > now() - interval '45 seconds' then raise exception '記録が正しくありません' using errcode = 'SR002'; end if;
  update public.solo_runs set done = true where id = p_run;
  insert into public.wallet (user_id) values (me) on conflict (user_id) do nothing;
  -- スタミナを消費して、経験値を足す
  select * into ss from public.stage_stamina where stage = r.stage;
  if found then
    select * into st from public.stamina_sync(me);
    left_st := greatest(0, st.val - ss.cost);
    update public.wallet set stamina = left_st,
      stamina_at = case when st.val >= st.mx and left_st < st.mx then now() else stamina_at end where user_id = me;
    update public.profiles set exp = exp + ss.exp where id = me returning exp into e_now;
    e_got := ss.exp;
    mx := public.stamina_max(public.lv_of(e_now));
  end if;
  select * into w from public.wallet where user_id = me for update;
  select * into rw from public.solo_rewards where stage = r.stage;
  if found then
    first := not (r.stage = any (w.solo_first));
    give := case when first then rw.first else rw.again end;
    update public.wallet set shards = shards + give, solo_first = case when first then solo_first || r.stage else solo_first end, updated_at = now()
      where user_id = me;
  end if;
  with ins as (
    insert into public.unlocks (user_id, id)
    select me, u.title from public.unlock_stages u where u.stage = r.stage and u.need <@ r.party
    on conflict do nothing returning id)
  select coalesce(array_agg(id), '{}') into got from ins;
  with ins2 as (
    insert into public.unlocks (user_id, id)
    select me, q.title from public.quest_drops q where q.stage = r.stage and random() < q.chance
    on conflict do nothing returning id)
  select coalesce(array_agg(id), '{}') into drop_got from ins2;
  return json_build_object('given', give, 'first', first, 'shards', w.shards + give, 'unlocked', got || drop_got,
    'exp_got', e_got, 'exp', e_now, 'stamina', left_st, 'max', mx);
end $$;

revoke execute on function public.stamina_get() from public, anon;
grant execute on function public.stamina_get() to authenticated;
revoke execute on function public.stamina_refill() from public, anon;
grant execute on function public.stamina_refill() to authenticated;

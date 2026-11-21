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

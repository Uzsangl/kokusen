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

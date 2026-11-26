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

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

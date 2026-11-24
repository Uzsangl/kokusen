-- ===== 19回目:降臨クエスト(毎日12時・18時・21時からの1時間だけ挑める) =====
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

-- 降臨が開いているか(日本時間で 12時台・18時台・21時台)
create or replace function public.quest_open() returns boolean
  language sql stable set search_path = '' as $$
  select extract(hour from (now() at time zone 'Asia/Tokyo'))::int in (12, 18, 21)
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

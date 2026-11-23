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

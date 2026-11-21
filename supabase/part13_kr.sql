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

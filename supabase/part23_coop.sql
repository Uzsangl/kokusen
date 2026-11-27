-- ===== 23回目:共闘降臨(3人マルチ)。★4はカサネ(mk5)、★5はゼノ【適応】(mx5) =====
-- ・ステージは mk5(★4)と mx5(★5)。どちらも消費スタミナ25・経験値2000、カケラは★5降臨と同じ(初回1000・2回目から30)
-- ・開催は降臨と同じ時間。quest_drops に当たり0%の行を入れて、solo_start の時間の確かめに乗せる
-- ・カサネの抽選(25%。★4だけ)は、部屋を開くとき(coop_open)にサーバーで1回だけ引く。勝った人は coop_claim で受け取る(当たれば3人とも)
-- ・同じ勝ちの記録で受け取れるのは1回だけ。1つの部屋で受け取れるのは3人まで

insert into public.stage_stamina (stage, cost, exp) values ('mk5', 25, 2000), ('mx5', 25, 2000)
  on conflict (stage) do update set cost = excluded.cost, exp = excluded.exp;
insert into public.solo_rewards (stage, first, again) values ('mk5', 1000, 30), ('mx5', 1000, 30)
  on conflict (stage) do update set first = excluded.first, again = excluded.again;
insert into public.quest_drops (stage, title, chance) values ('mk5', 'kasane', 0), ('mx5', 'kasane', 0)
  on conflict (stage) do update set title = excluded.title, chance = excluded.chance;

create table if not exists public.coop_rooms (
  id uuid primary key default gen_random_uuid(),
  stage text not null,
  host uuid not null references auth.users on delete cascade,
  hit boolean not null,
  created_at timestamptz not null default now()
);
alter table public.coop_rooms enable row level security;
revoke all on public.coop_rooms from anon, authenticated;
create table if not exists public.coop_claims (
  run uuid primary key,
  room uuid not null references public.coop_rooms on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.coop_claims enable row level security;
revoke all on public.coop_claims from anon, authenticated;

-- 部屋を開く(ホストだけが呼ぶ)。降臨の時間内だけ。1時間に30部屋まで
create or replace function public.coop_open(p_stage text, p_ver text) returns uuid
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); rid uuid;
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_stage is null or p_stage not in ('mk5', 'mx5') then raise exception 'このステージは共闘降臨ではありません'; end if;
  if not public.quest_open() then raise exception '降臨の時間外です' using errcode = 'QS001'; end if;
  if (select count(*) from public.coop_rooms where host = me and created_at > now() - interval '1 hour') >= 30 then
    raise exception '少し時間をおいてください' using errcode = 'CO001';
  end if;
  delete from public.coop_rooms where created_at < now() - interval '2 days';
  insert into public.coop_rooms (stage, host, hit) values (p_stage, me, p_stage = 'mk5' and random() < 0.25) returning id into rid;
  return rid;
end $$;

-- 勝った記録(solo_reward 済みの挑戦)を見せて、部屋の当たりを受け取る
create or replace function public.coop_claim(p_room uuid, p_run uuid, p_ver text) returns json
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); rm public.coop_rooms; r public.solo_runs; got text[] := '{}';
begin
  perform public.ver_check(p_ver);
  if me is null then raise exception 'ログインが必要です'; end if;
  select * into rm from public.coop_rooms where id = p_room;
  if not found or rm.created_at < now() - interval '3 hours' then return json_build_object('unlocked', got); end if;
  select * into r from public.solo_runs where id = p_run and user_id = me;
  if not found or not r.done or r.stage <> rm.stage or r.started_at < rm.created_at - interval '1 minute' then return json_build_object('unlocked', got); end if;
  if (select count(*) from public.coop_claims where room = p_room) >= 3 then return json_build_object('unlocked', got); end if;
  insert into public.coop_claims (run, room, user_id) values (p_run, p_room, me) on conflict (run) do nothing;
  if not found then return json_build_object('unlocked', got); end if;
  if rm.hit then
    with ins as (insert into public.unlocks (user_id, id) values (me, 'kasane') on conflict do nothing returning id)
    select coalesce(array_agg(id), '{}') into got from ins;
  end if;
  return json_build_object('unlocked', got);
end $$;

revoke execute on function public.coop_open(text, text) from public, anon;
grant execute on function public.coop_open(text, text) to authenticated;
revoke execute on function public.coop_claim(uuid, uuid, text) from public, anon;
grant execute on function public.coop_claim(uuid, uuid, text) to authenticated;

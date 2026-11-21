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

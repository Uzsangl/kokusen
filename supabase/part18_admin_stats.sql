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

-- ===== 14回目:刻練場の記録の取りこぼしを直す(古い版で遊んで、サーバーに届かなかった分) =====
-- 1) 確認:端末側(progress.stats)の累計のほうが、サーバー(kr_scores)より多い人
select p.name,
       coalesce((g.stats->>'krTotal')::int, 0) as 端末側の累計,
       coalesce(s.total_kills, 0)              as サーバーの累計,
       coalesce((g.stats->>'krKills')::int, 0) as 端末側の最高撃破,
       coalesce(s.best_kills, 0)               as サーバーの最高撃破
from public.progress g
join public.profiles p on p.id = g.id
left join public.kr_scores s on s.user_id = g.id
where coalesce((g.stats->>'krTotal')::int, 0) > coalesce(s.total_kills, 0);

-- 2) 直す:名前を指定した人だけ、端末側の値をサーバーに入れる(大きいほうを残す)
-- insert into public.kr_scores (user_id, best_kills, best_layers, total_kills, runs)
-- select g.id, coalesce((g.stats->>'krKills')::int, 0), coalesce((g.stats->>'krBest')::int, 0), coalesce((g.stats->>'krTotal')::int, 0), 0
-- from public.progress g join public.profiles p on p.id = g.id
-- where p.name = 'ここに名前'
-- on conflict (user_id) do update set
--   total_kills = greatest(public.kr_scores.total_kills, excluded.total_kills),
--   best_kills  = greatest(public.kr_scores.best_kills,  excluded.best_kills),
--   best_layers = greatest(public.kr_scores.best_layers, excluded.best_layers);

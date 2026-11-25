-- ===== 20回目:降臨の開催時間を変える(毎日 8:00〜10:00・12:00〜14:00・18:00〜20:00・21:00〜24:00) =====
create or replace function public.quest_open() returns boolean
  language sql stable set search_path = '' as $$
  select extract(hour from (now() at time zone 'Asia/Tokyo'))::int in (8, 9, 12, 13, 18, 19, 21, 22, 23)
$$;

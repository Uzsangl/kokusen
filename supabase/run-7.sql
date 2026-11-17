-- supabase/schema.sql の「7回目」だけを抜き出したもの(スマホで全選択してコピーしやすくするため)。中身は schema.sql と同じ
-- ===== 7回目:同じ相手とのレート戦は1日5回まで(2つのアカウントでレートを上げる不正の対策) =====
-- rate_start を置き換える。上限を超えたら、エラー KS001 を返してレートを動かさない(対戦そのものはできる)
create or replace function public.rate_start(p_key text, p_foe uuid) returns json
  language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  x uuid; y uuid; m public.matches; is_a boolean;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  if p_foe is null or p_foe = me then raise exception '相手が正しくありません'; end if;
  x := least(me, p_foe); y := greatest(me, p_foe); is_a := (me = x);
  -- 同じ相手とのレート戦は1日5回まで(二人とも始めた対戦だけを数える)。6回目からはレートを動かさない
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
revoke execute on function public.rate_start(text, uuid) from public, anon;
grant execute on function public.rate_start(text, uuid) to authenticated;

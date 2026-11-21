-- ===== 11回目:運営(マスター)の観戦(不正対策) =====
-- ログイン中のプレイヤーは、フレンドの観戦の設定とは別に、運営だけが入れる観戦の部屋を開く。
-- 部屋の名前は「運営観戦の鍵」から作り、鍵は本人と運営(マスター)にしか返さない
create table if not exists public.audit_keys (
  user_id uuid primary key references auth.users on delete cascade,
  audit_key text not null
);
alter table public.audit_keys enable row level security;

-- 自分の運営観戦の鍵(なければ作る)
create or replace function public.audit_me() returns text
  language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); k text;
begin
  if me is null then raise exception 'ログインが必要です'; end if;
  insert into public.audit_keys (user_id, audit_key) values (me, public.friend_rand(20)) on conflict (user_id) do nothing;
  select audit_key into k from public.audit_keys where user_id = me;
  return k;
end $$;

-- 呼んだ人がマスターか(ログイン中のメールアドレスの SHA-256 で確かめる。index.html の MASTER_HASHES と同じ)
create or replace function public.is_master() returns boolean
  language sql stable security definer set search_path = '' as
  $$ select coalesce(encode(pg_catalog.sha256(convert_to(lower(trim(auth.jwt() ->> 'email')), 'UTF8')), 'hex')
       = any (array['6bc4a36350f6ff8d567a477610dca5984216523e41ce0a92245a24c207916900']), false) $$;

-- ログイン中のプレイヤーの一覧と、運営観戦の鍵(マスターだけ)
create or replace function public.audit_list() returns table (id uuid, name text, st jsonb, seen_at timestamptz, key text)
  language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_master() then raise exception '権限がありません'; end if;
  return query
    select s.user_id, p.name, s.st, s.seen_at, k.audit_key
    from public.user_status s
    join public.profiles p on p.id = s.user_id
    left join public.audit_keys k on k.user_id = s.user_id
    where s.seen_at > now() - interval '3 minutes' and s.user_id <> auth.uid()
    order by s.seen_at desc
    limit 200;
end $$;

revoke execute on function public.audit_me() from public, anon;
revoke execute on function public.is_master() from public, anon;
revoke execute on function public.audit_list() from public, anon;
grant execute on function public.audit_me() to authenticated;
grant execute on function public.is_master() to authenticated;
grant execute on function public.audit_list() to authenticated;

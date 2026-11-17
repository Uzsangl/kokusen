-- 刻戦のアカウント用の表(Supabase の SQL Editor で実行する)

-- ===== 1回目(最初に実行したもの) =====
-- プレイヤー情報(名前・レーティング)。ランキング用に誰でも読める
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null default '名無し' check (char_length(name) between 1 and 12),
  rating int not null default 1500,
  wins int not null default 0,
  losses int not null default 0,
  cleared text[] not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "誰でも読める" on public.profiles for select using (true);
create policy "自分の行だけ作れる" on public.profiles for insert with check (auth.uid() = id);
create policy "自分の行だけ書ける" on public.profiles for update using (auth.uid() = id);

-- ===== 2回目:非公開の記録を分け、称号の列を足す =====
-- クリア記録などは、本人だけが読める表に移す(profiles は全員に公開されるため)
create table if not exists public.progress (
  id uuid primary key references auth.users on delete cascade,
  cleared text[] not null default '{}',
  stats jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.progress enable row level security;
create policy "自分だけ読める" on public.progress for select using (auth.uid() = id);
create policy "自分だけ作れる" on public.progress for insert with check (auth.uid() = id);
create policy "自分だけ書ける" on public.progress for update using (auth.uid() = id);
insert into public.progress (id, cleared) select id, cleared from public.profiles on conflict (id) do nothing;
alter table public.profiles drop column if exists cleared;
-- 称号:選んでいる称号と、解放した称号の一覧(公開)
alter table public.profiles add column if not exists title text not null default '';
alter table public.profiles add column if not exists titles text[] not null default '{}';

-- ===== 3回目:お気に入りキャラ =====
alter table public.profiles add column if not exists fav text not null default '';

-- ===== 4回目:招待コード =====
-- 招待コード:アカウントのIDから作る8文字(公開)。コードから招待した人を探すのに使う
alter table public.profiles add column if not exists invite_code text generated always as (upper(substr(md5(id::text), 1, 8))) stored;
create unique index if not exists profiles_invite_code on public.profiles (invite_code);
-- 招待の記録:招待された人1人につき1行(1回しか使えない)。自分を招待はできない
create table if not exists public.invites (
  invitee uuid primary key references auth.users on delete cascade,
  inviter uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  check (invitee <> inviter)
);
alter table public.invites enable row level security;
-- 作ってから1日以内のアカウントか(サーバーの登録日時で確かめる)
create or replace function public.is_new_account() returns boolean
  language sql stable security definer set search_path = '' as
  $$ select exists (select 1 from auth.users where id = auth.uid() and created_at > now() - interval '1 day') $$;
create policy "招待:本人と招待した人だけ見られる" on public.invites for select using (auth.uid() = invitee or auth.uid() = inviter);
create policy "招待:作って1日以内の本人だけ登録できる" on public.invites for insert with check (auth.uid() = invitee and public.is_new_account());

-- ===== 5回目:招待は1人5人まで(アカウント量産の対策) =====
-- 招待した人数を数える(招待された側からは他人の行が見えないため、数だけを返す関数にする)
create or replace function public.invite_count(u uuid) returns int
  language sql stable security definer set search_path = '' as
  $$ select count(*)::int from public.invites where inviter = u $$;
drop policy if exists "招待:作って1日以内の本人だけ登録できる" on public.invites;
create policy "招待:作って1日以内の本人だけ・招待は5人まで" on public.invites for insert
  with check (auth.uid() = invitee and public.is_new_account() and public.invite_count(inviter) < 5);

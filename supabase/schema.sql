-- 刻戦のアカウント用の表(Supabase の SQL Editor で一度だけ実行する)
-- プレイヤー情報(名前・レーティング・ソロのクリア記録)。ランキング用に誰でも読める
create table public.profiles (
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

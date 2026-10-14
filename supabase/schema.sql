-- そっと報告: Supabase用のデータベース設定
-- 使い方: Supabaseの「SQL Editor」にこのファイルの中身を全部貼り付けて「Run」を押します。
-- 何回実行しても壊れないようにしてあります（作り直したいときは先頭の drop 文を使います）。

-- ===== 部屋 =====
create table if not exists public.rooms (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,                 -- 合言葉（大文字英数字8桁）
  -- 二人用。端末を変えて入り直したときのために、少し余裕（4）を持たせています
  max_members int  not null default 4 check (max_members between 2 and 6),
  created_by  uuid not null default auth.uid(),
  created_at  timestamptz not null default now()
);

create table if not exists public.room_members (
  room_id   uuid not null references public.rooms(id) on delete cascade,
  user_id   uuid not null,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index if not exists room_members_user_idx on public.room_members(user_id);

-- 呼び名（誰の発言か表示するため。12文字まで）
alter table public.room_members
  add column if not exists nickname text
  check (char_length(nickname) between 1 and 12 and nickname !~ '[\r\n]');

-- ===== メッセージ（定型だけ。自由な文章は保存できない作りです）=====
-- 保存するのは「どの出来事・伝え方・トーンか」という選択だけで、文面は受け取った側のアプリが組み立てます。
create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms(id) on delete cascade,
  sender_id  uuid not null default auth.uid(),
  kind       text not null check (kind in ('report','reply')),

  -- 報告
  event_key  text check (event_key in ('light','cups','dishes','trash','laundry','lock','clothes','fridge','custom')),
  mode       text check (mode in ('did','inf','ask')),
  tone       text check (tone in ('yuru','kawaii','sappari')),
  variant    int  not null default 0 check (variant between 0 and 9),
  thanks     boolean not null default false,
  -- 「ほかのこと」用: 物の名前（短い言葉）と、選択式の状態・やったこと
  noun       text check (char_length(noun) between 1 and 12 and noun !~ '[\r\n]'),
  state_key  text check (state_key in ('on','out','piled','open','left')),
  action_key text check (action_key in ('none','off','tidy','wash','close','takeout','fold')),

  -- 返信（定型のみ）
  reply_key  text check (reply_key in ('thanks','ok','later','sorry','seen')),
  reply_to   uuid references public.messages(id) on delete set null,

  created_at timestamptz not null default now(),
  read_at    timestamptz,

  constraint report_fields check (
    kind <> 'report' or (event_key is not null and mode is not null and tone is not null and reply_key is null)
  ),
  constraint custom_fields check (
    event_key is distinct from 'custom' or (noun is not null and state_key is not null and action_key is not null)
  ),
  constraint reply_fields check (
    kind <> 'reply' or (reply_key is not null and event_key is null)
  )
);
create index if not exists messages_room_time_idx on public.messages(room_id, created_at desc);

-- ===== 権限（RLS）=====
alter table public.rooms        enable row level security;
alter table public.room_members enable row level security;
alter table public.messages     enable row level security;

create or replace function public.is_room_member(rid uuid)
returns boolean
language sql security definer stable
set search_path = public
as $$
  select exists (select 1 from public.room_members where room_id = rid and user_id = auth.uid());
$$;

drop policy if exists rooms_select on public.rooms;
create policy rooms_select on public.rooms
  for select to authenticated using (public.is_room_member(id));

drop policy if exists members_select on public.room_members;
create policy members_select on public.room_members
  for select to authenticated using (public.is_room_member(room_id));

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages
  for select to authenticated using (public.is_room_member(room_id));

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages
  for insert to authenticated
  with check (sender_id = auth.uid() and public.is_room_member(room_id));

-- 相手のメッセージを「読んだ」にできる（read_at だけ更新可）
drop policy if exists messages_mark_read on public.messages;
create policy messages_mark_read on public.messages
  for update to authenticated
  using (public.is_room_member(room_id) and sender_id <> auth.uid())
  with check (public.is_room_member(room_id) and sender_id <> auth.uid());

-- 自分が送ったものは取り消せる
drop policy if exists messages_delete_own on public.messages;
create policy messages_delete_own on public.messages
  for delete to authenticated using (sender_id = auth.uid());

revoke all on public.rooms, public.room_members, public.messages from anon, authenticated;
grant select on public.rooms, public.room_members to authenticated;
grant select, insert, delete on public.messages to authenticated;
grant update (read_at) on public.messages to authenticated;

-- ===== 部屋の作成・入室（アプリはこの2つだけを呼びます）=====
create or replace function public.create_room()
returns table (room_id uuid, code text)
language plpgsql security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- 読み間違えやすい文字(I,L,O,0,1)を除外
  idx int[] := array[0,1,2,3,4,5,10,11];
  bytes bytea;
  c text;
  rid uuid;
  tries int := 0;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if (select count(*) from rooms where created_by = uid) >= 5 then
    raise exception 'too_many_rooms';
  end if;
  loop
    bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    c := '';
    for i in 1..8 loop
      c := c || substr(alphabet, (get_byte(bytes, idx[i]) % 31) + 1, 1);
    end loop;
    begin
      insert into rooms(code, created_by) values (c, uid) returning id into rid;
      exit;
    exception when unique_violation then
      tries := tries + 1;
      if tries > 5 then raise exception 'code_generation_failed'; end if;
    end;
  end loop;
  insert into room_members(room_id, user_id) values (rid, uid);
  return query select rid, c;
end;
$$;

create or replace function public.join_room(p_code text)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  rid uuid;
  mx int;
  cnt int;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select id, max_members into rid, mx
    from rooms
   where code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
   for update;
  if rid is null then raise exception 'room_not_found'; end if;
  if exists (select 1 from room_members where room_id = rid and user_id = uid) then
    return rid;
  end if;
  select count(*) into cnt from room_members where room_id = rid;
  if cnt >= mx then raise exception 'room_full'; end if;
  insert into room_members(room_id, user_id) values (rid, uid);
  return rid;
end;
$$;

revoke all on function public.create_room()        from public, anon;
revoke all on function public.join_room(text)      from public, anon;
revoke all on function public.is_room_member(uuid) from public, anon;
grant execute on function public.create_room()        to authenticated;
grant execute on function public.join_room(text)      to authenticated;
grant execute on function public.is_room_member(uuid) to authenticated;

-- ===== 呼び名の設定（自分の行だけ変えられる）=====
create or replace function public.set_nickname(p_room uuid, p_name text)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update room_members
     set nickname = nullif(btrim(coalesce(p_name, '')), '')
   where room_id = p_room and user_id = auth.uid();
end;
$$;
revoke all on function public.set_nickname(uuid, text) from public, anon;
grant execute on function public.set_nickname(uuid, text) to authenticated;

-- ===== リアルタイム配信（メッセージが相手の画面にすぐ出るようにする）=====
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'room_members'
  ) then
    alter publication supabase_realtime add table public.room_members;
  end if;
end $$;

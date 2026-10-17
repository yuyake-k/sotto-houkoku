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
-- 全員が退室した時刻（この日から7日たつと、部屋とやりとりを消す）
alter table public.rooms add column if not exists emptied_at timestamptz;

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
  mode       text check (mode in ('did','inf','ask','thx')),
  tone       text check (tone in ('yuru','kawaii','sappari')),
  variant    int  not null default 0 check (variant between 0 and 999),
  thanks     boolean not null default false,
  -- 「ほかのこと」用: 物の名前（短い言葉）と、選択式の状態・やったこと
  noun       text check (char_length(noun) between 1 and 12 and noun !~ '[\r\n]'),
  -- 選択肢はアプリ側で増やせるように、英小文字の短い名前なら保存できる（文章は保存できない）
  state_key  text check (state_key ~ '^[a-z]{1,12}$'),
  action_key text check (action_key ~ '^[a-z]{1,12}$'),

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

-- ===== 引き継ぎ（別の端末で、同じ人として使う）=====
-- 引き継ぎコード（照合用の値だけを保存。15分で無効、1回で使い切り）
create table if not exists public.identity_transfers (
  code_hash  text primary key,
  user_id    uuid not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
-- 引き継ぎずみの端末（古い側）。ここに入った人は、新しく部屋をつくったり入ったりできない
create table if not exists public.transferred_users (
  user_id uuid primary key,
  moved_at timestamptz not null default now()
);
-- コードの入力ミスの記録（総当たりを防ぐ）
create table if not exists public.transfer_attempts (
  user_id uuid not null,
  at      timestamptz not null default now()
);
create index if not exists transfer_attempts_at_idx on public.transfer_attempts(at);
alter table public.identity_transfers enable row level security;
alter table public.transferred_users  enable row level security;
alter table public.transfer_attempts  enable row level security;
revoke all on public.identity_transfers, public.transferred_users, public.transfer_attempts from anon, authenticated;

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
  if exists (select 1 from transferred_users where user_id = uid) then raise exception 'identity_moved'; end if;
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
  if exists (select 1 from transferred_users where user_id = uid) then raise exception 'identity_moved'; end if;
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
  update rooms set emptied_at = null where id = rid and emptied_at is not null;
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

-- ===== 退室（全員が退室して7日たつと、部屋ごと消える）=====
-- 全員が退室して7日たった部屋を消す（やりとりは部屋と一緒に消える）
create or replace function public.purge_empty_rooms()
returns void
language sql security definer
set search_path = public
as $$
  delete from rooms
   where emptied_at is not null
     and emptied_at < now() - interval '7 days'
     and not exists (select 1 from room_members m where m.room_id = rooms.id);
$$;
revoke all on function public.purge_empty_rooms() from public, anon, authenticated;

create or replace function public.leave_room(p_room uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cnt int;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  perform 1 from rooms where id = p_room for update;
  delete from room_members where room_id = p_room and user_id = uid;
  select count(*) into cnt from room_members where room_id = p_room;
  if cnt = 0 then
    update rooms set emptied_at = coalesce(emptied_at, now()) where id = p_room;
  end if;
  perform public.purge_empty_rooms();
end;
$$;
revoke all on function public.leave_room(uuid) from public, anon;
grant execute on function public.leave_room(uuid) to authenticated;

-- 毎日、決まった時刻にも掃除する（pg_cron が使えるときだけ。使えなくてもアプリは動きます）
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('sotto-purge-empty-rooms', '17 3 * * *', 'select public.purge_empty_rooms()');
exception when others then
  raise notice 'pg_cron を設定できませんでした（退室や入室のたびに掃除されるので、そのままで大丈夫です）: %', sqlerrm;
end $$;

-- 引き継ぎコードを出す（この端末の人を、別の端末に移すためのコード）
create or replace function public.create_transfer_code()
returns text
language plpgsql security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- 読み間違えやすい文字を除外
  idx int[] := array[0,1,2,3,4,5,10,11,12,13,14,15];
  bytes bytea;
  c text := '';
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if exists (select 1 from transferred_users where user_id = uid) then raise exception 'identity_moved'; end if;
  delete from identity_transfers where user_id = uid or expires_at < now();
  bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
  for i in 1..12 loop
    c := c || substr(alphabet, (get_byte(bytes, idx[i]) % 31) + 1, 1);
  end loop;
  insert into identity_transfers(code_hash, user_id, expires_at)
  values (encode(sha256(convert_to(c, 'UTF8')), 'hex'), uid, now() + interval '15 minutes');
  return c;
end;
$$;

-- 引き継ぎコードを使う（この端末を、コードを出した人として扱う）
-- 返事: ok / invalid（コード違い・期限切れ）/ too_many（入力ミスが多い）/ same（同じ端末）
create or replace function public.claim_transfer(p_code text)
returns text
language plpgsql security definer
set search_path = public
as $$
declare
  newu uuid := auth.uid();
  oldu uuid;
  h text;
begin
  if newu is null then raise exception 'not_authenticated'; end if;
  delete from transfer_attempts where at < now() - interval '1 hour';
  if (select count(*) from transfer_attempts where user_id = newu and at > now() - interval '15 minutes') >= 5
     or (select count(*) from transfer_attempts where at > now() - interval '10 minutes') >= 200 then
    return 'too_many';
  end if;
  h := encode(sha256(convert_to(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'UTF8')), 'hex');
  select user_id into oldu from identity_transfers where code_hash = h and expires_at > now() for update;
  if oldu is null then
    insert into transfer_attempts(user_id) values (newu);
    return 'invalid';
  end if;
  if oldu = newu then return 'same'; end if;

  -- 同じ部屋に、この端末の人がすでにいる場合は、古い側の行を消す
  delete from room_members
   where user_id = oldu
     and room_id in (select room_id from room_members where user_id = newu);
  update room_members set user_id = newu where user_id = oldu;
  update messages     set sender_id = newu where sender_id = oldu;
  update rooms        set created_by = newu where created_by = oldu;
  if to_regclass('public.push_subscriptions') is not null then
    execute 'delete from public.push_subscriptions where user_id = $1' using oldu;
  end if;
  delete from identity_transfers where user_id = oldu;
  insert into transferred_users(user_id) values (oldu) on conflict do nothing;
  return 'ok';
end;
$$;

revoke all on function public.create_transfer_code()  from public, anon;
revoke all on function public.claim_transfer(text)    from public, anon;
grant execute on function public.create_transfer_code() to authenticated;
grant execute on function public.claim_transfer(text)   to authenticated;

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

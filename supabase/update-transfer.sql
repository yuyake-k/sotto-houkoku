-- 引き継ぎの機能を足すための追加分（schema.sql を実行済みなら、これだけを実行します）

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

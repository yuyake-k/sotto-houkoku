-- 退室の機能を足すための追加分（schema.sql を実行済みなら、これだけを実行します）
-- 退室すると自分の枠が空きます。全員が退室して7日たつと、部屋とやりとりが消えます。
-- （7日のあいだは、合言葉があれば同じ部屋に戻れます）

alter table public.rooms add column if not exists emptied_at timestamptz;

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

-- 入り直したら「全員退室」の印を外す
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
  update rooms set emptied_at = null where id = rid and emptied_at is not null;
  return rid;
end;
$$;
revoke all on function public.join_room(text) from public, anon;
grant execute on function public.join_room(text) to authenticated;

-- 毎日、決まった時刻にも掃除する（pg_cron が使えるときだけ。使えなくてもアプリは動きます）
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('sotto-purge-empty-rooms', '17 3 * * *', 'select public.purge_empty_rooms()');
exception when others then
  raise notice 'pg_cron を設定できませんでした（退室や入室のたびに掃除されるので、そのままで大丈夫です）: %', sqlerrm;
end $$;

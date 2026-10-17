-- プロフィール画像の機能を足すための追加分（すでに schema.sql を実行済みの場合は、これだけを実行します）
alter table public.room_members
  add column if not exists avatar text
  check (avatar ~ '^[a-z0-9]{1,16}$');

create or replace function public.set_avatar(p_room uuid, p_key text)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update room_members
     set avatar = nullif(btrim(coalesce(p_key, '')), '')
   where room_id = p_room and user_id = auth.uid();
end;
$$;
revoke all on function public.set_avatar(uuid, text) from public, anon;
grant execute on function public.set_avatar(uuid, text) to authenticated;

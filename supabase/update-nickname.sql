-- 呼び名の機能を足すための追加分（すでに schema.sql を実行済みの場合は、これだけを実行します）
alter table public.room_members
  add column if not exists nickname text
  check (char_length(nickname) between 1 and 12 and nickname !~ '[\r\n]');

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

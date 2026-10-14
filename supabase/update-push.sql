-- 通知の機能を足すための追加分（Supabaseの SQL Editor で実行します）
-- ※ __WEBHOOK_SECRET__ の部分は、手順書で渡された合言葉に置き換えてから実行します。

-- 通知の宛先（端末ごと）。アプリからは下の2つの関数でしか触れません
create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;

create or replace function public.save_push(p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000 then raise exception 'bad_endpoint'; end if;
  insert into push_subscriptions(endpoint, user_id, p256dh, auth)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end;
$$;

create or replace function public.delete_push(p_endpoint text)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
end;
$$;

revoke all on function public.save_push(text, text, text)  from public, anon;
revoke all on function public.delete_push(text)            from public, anon;
grant execute on function public.save_push(text, text, text) to authenticated;
grant execute on function public.delete_push(text)           to authenticated;

-- 通知を送る係（Edge Function）が、部屋のメンバーと通知の宛先を読めるようにする
grant usage on schema public to service_role;
grant select on public.room_members to service_role;
grant select, delete on public.push_subscriptions to service_role;

-- 新しいメッセージが入ったら、通知を送る係（Edge Function）を呼ぶ
-- 失敗しても、メッセージの保存には影響しません
create extension if not exists pg_net with schema extensions;

create or replace function public.notify_new_message()
returns trigger
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  begin
    perform net.http_post(
      url     := 'https://pbzrhnkjtcpouplvewok.supabase.co/functions/v1/notify',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', '__WEBHOOK_SECRET__'),
      body    := jsonb_build_object('room_id', new.room_id, 'sender_id', new.sender_id, 'kind', new.kind)
    );
  exception when others then
    null;
  end;
  return null;
end;
$$;
revoke all on function public.notify_new_message() from public, anon, authenticated;

drop trigger if exists messages_notify on public.messages;
create trigger messages_notify after insert on public.messages
  for each row execute function public.notify_new_message();

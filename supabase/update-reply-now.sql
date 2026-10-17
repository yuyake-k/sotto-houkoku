-- 返信（ありがとう・了解など）は、30分待たずにすぐ相手へ通知するSQL（SQL Editor で実行します）
-- ・報告は、今まで通り30分後に通知します。
-- ・先に update-delay.sql が入っている必要があります。
-- ・__WEBHOOK_SECRET__ は、これまでと同じ合言葉に置き換えてから実行してください。

create or replace function public.notify_reply_now()
returns trigger
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  nick text;
  ttl text;
begin
  begin
    select nickname into nick from room_members where room_id = new.room_id and user_id = new.sender_id;
    ttl := coalesce(nullif(nick, ''), '相手') || 'から';
    perform net.http_post(
      url     := 'https://pbzrhnkjtcpouplvewok.supabase.co/functions/v1/dynamic-worker',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', '__WEBHOOK_SECRET__'),
      body    := jsonb_build_object('room_id', new.room_id, 'sender_id', new.sender_id, 'kind', 'reply', 'title', ttl, 'body', '返信が届いています')
    );
    -- 送れたら「通知済み」にして、30分後の通知で二重に送らない
    update messages set notified_at = now() where id = new.id;
  exception when others then
    null;  -- 失敗しても、30分後の通知が代わりに送ります
  end;
  return null;
end;
$$;
revoke all on function public.notify_reply_now() from public, anon, authenticated;

drop trigger if exists messages_reply_now on public.messages;
create trigger messages_reply_now after insert on public.messages
  for each row when (new.kind = 'reply')
  execute function public.notify_reply_now();

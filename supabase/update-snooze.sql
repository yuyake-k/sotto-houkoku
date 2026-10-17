-- 「あとでやるね」を選んだ人に、30分後に自分へお知らせを送るSQL（SQL Editor で実行します）
-- ・先に update-delay.sql（30分後に通知する仕組み）が入っている必要があります。
-- ・__WEBHOOK_SECRET__ は、これまでと同じ合言葉に置き換えてから実行してください。
-- ・あわせて、通知の関数（notify）を v4 に入れ替えてください（自分あての通知に対応します）。

alter table public.messages add column if not exists snoozed_at timestamptz;
-- これまでの「あとでやるね」は対象にしない
update public.messages set snoozed_at = now() where kind = 'reply' and reply_key = 'later' and snoozed_at is null;

create or replace function public.dispatch_due_notifications()
returns int
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  m record;
  nick text;
  ttl text;
  bdy text;
  n int := 0;
begin
  -- 1) 届いた30分後に、相手へ通知
  for m in
    select id, room_id, sender_id, kind from messages
     where notified_at is null
       and created_at <= now() - interval '30 minutes'
     order by created_at
     limit 50
     for update skip locked
  loop
    update messages set notified_at = now() where id = m.id;
    begin
      select nickname into nick from room_members where room_id = m.room_id and user_id = m.sender_id;
      ttl := coalesce(nullif(nick, ''), '相手') || 'から';
      bdy := case when m.kind = 'reply' then '返信が届いています' else '届いています（急ぎじゃないよ）' end;
      perform net.http_post(
        url     := 'https://pbzrhnkjtcpouplvewok.supabase.co/functions/v1/dynamic-worker',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', '__WEBHOOK_SECRET__'),
        body    := jsonb_build_object('room_id', m.room_id, 'sender_id', m.sender_id, 'kind', m.kind, 'title', ttl, 'body', bdy)
      );
      n := n + 1;
    exception when others then
      null;
    end;
  end loop;

  -- 2) 「あとでやるね」の30分後に、本人へお知らせ（あとで別の返信をしていたら送らない）
  for m in
    select x.id, x.room_id, x.sender_id, x.reply_to from messages x
     where x.kind = 'reply' and x.reply_key = 'later'
       and x.snoozed_at is null
       and x.created_at <= now() - interval '30 minutes'
       and exists (select 1 from room_members rm where rm.room_id = x.room_id and rm.user_id = x.sender_id)
       and not exists (
         select 1 from messages y
          where y.kind = 'reply' and y.sender_id = x.sender_id
            and y.reply_to is not distinct from x.reply_to
            and y.created_at > x.created_at)
     order by x.created_at
     limit 50
     for update skip locked
  loop
    update messages set snoozed_at = now() where id = m.id;
    begin
      select rm.nickname into nick
        from messages o join room_members rm on rm.room_id = o.room_id and rm.user_id = o.sender_id
       where o.id = m.reply_to;
      ttl := 'そっと報告';
      bdy := coalesce(nullif(nick, ''), '相手') || 'の報告、手が空いたときにどうぞ🌿';
      perform net.http_post(
        url     := 'https://pbzrhnkjtcpouplvewok.supabase.co/functions/v1/dynamic-worker',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', '__WEBHOOK_SECRET__'),
        body    := jsonb_build_object('room_id', m.room_id, 'sender_id', m.sender_id, 'kind', 'snooze', 'target', 'self', 'title', ttl, 'body', bdy)
      );
      n := n + 1;
    exception when others then
      null;
    end;
  end loop;
  return n;
end;
$$;
revoke all on function public.dispatch_due_notifications() from public, anon, authenticated;

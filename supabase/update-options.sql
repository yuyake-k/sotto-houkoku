-- 「どうなってた？」「やったこと」の選択肢を増やすための追加分
-- （アプリ側で選択肢を足しても、データベースを直さなくていいようにします）
alter table public.messages drop constraint if exists messages_state_key_check;
alter table public.messages drop constraint if exists messages_action_key_check;
alter table public.messages drop constraint if exists messages_state_key_fmt;
alter table public.messages drop constraint if exists messages_action_key_fmt;
alter table public.messages add constraint messages_state_key_fmt  check (state_key  ~ '^[a-z]{1,12}$');
alter table public.messages add constraint messages_action_key_fmt check (action_key ~ '^[a-z]{1,12}$');

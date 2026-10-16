-- 言い回しを自分で選べるようにするSQL（SQL Editor で実行します）
-- 選んだ言い回しの番号を保存するため、messages.variant の上限（9）を広げます。
-- 今までのメッセージは、そのまま読めます。
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.messages'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) like '%variant%'
  loop
    execute format('alter table public.messages drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.messages
  add constraint messages_variant_check check (variant between 0 and 999);

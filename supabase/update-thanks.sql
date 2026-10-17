-- 「ありがとう」を伝える報告を使えるようにするSQL（SQL Editor で実行します）
-- messages.mode に 'thx'（ありがとう）を足します。今までのメッセージはそのまま読めます。
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.messages'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) like '%''inf''%' and pg_get_constraintdef(oid) like '%mode%'
  loop
    execute format('alter table public.messages drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.messages
  add constraint messages_mode_check check (mode in ('did','inf','ask','thx'));

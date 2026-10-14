# そっと報告 セットアップ手順

中身は2つです。

- `supabase/schema.sql` : メッセージの保存先の設定（Supabaseに貼る）
- `app/` : アプリ本体（ホスティングに置く）

## 1. Supabase側の設定

1. Supabaseのプロジェクトを開き、左のメニューから **SQL Editor** を開く
2. `supabase/schema.sql` の中身を全部貼り付けて **Run** を押す（何回押しても大丈夫です）
3. **Authentication** の設定で **Anonymous sign-ins** をオンにする
4. **Project Settings の API** の画面で、**Project URL** と **anon key（Publishable key）** を控える

## 2. アプリに接続情報を入れる

（このzipの `app/config.js` には、接続情報をすでに入れてあります。別のプロジェクトで使うときだけ、次の2つの値を書き換えます。）

```
window.SOTTO_CONFIG = {
  url: "https://xxxxxxxx.supabase.co",
  anonKey: "ここにanon key"
};
```

service_role / secret と書かれたキーは入れないでください。

## 3. 公開する

`app` フォルダごと、次のどれかに置きます（どれも無料で足ります）。

- Netlify Drop（app.netlify.com/drop に、フォルダをドラッグするだけ）
- Cloudflare Pages
- GitHub Pages

できたURLをiPhoneのSafariで開きます。

## 4. iPhoneで使う（二人とも同じ手順）

1. SafariでURLを開く
2. 共有ボタンから **ホーム画面に追加**
3. **ホーム画面のアイコンから**開く（先にSafariで入室しないでください。Safariとホーム画面のアプリは、記憶が別になります）
4. 一人目: 「部屋をつくる」を押し、出た合言葉を相手に送る
5. 二人目: 「合言葉をもらった」に入力して「部屋に入る」

## 仕様メモ

- 送れるのは定型だけです。返信も定型だけです。自由な文章はデータベースの設計上、保存できません
- 既読表示はありません（プレッシャーになりそうなため）
- 複数の部屋に入れます（「いちらん」から切り替え）。「設定」から退室できます。全員が退室して7日たつと、部屋とやりとりは消えます（7日のあいだは合言葉で戻れます）
- 呼び名の機能は `supabase/update-nickname.sql`、退室の機能は `supabase/update-leave.sql` を、SQL Editorで実行します（`schema.sql` を最初から実行した場合は不要です）
- 別の端末へは、「設定」の引き継ぎコード（15分・1回限り）で、同じ人のまま移れます（`supabase/update-transfer.sql`）。メールなどの個人情報は持ちません
- 端末を変えて入り直すときは、同じ合言葉で入れます（部屋は4人分の空きがあります）。その場合、以前に自分が送ったメッセージは「相手」側の表示になります
- 通知はまだありません。新着は、画面を開いたときに出ます

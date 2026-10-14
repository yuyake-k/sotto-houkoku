// 新しいメッセージが入ったとき、同じ部屋の相手の端末に通知を送ります。
// 通知に出るのは「新着があります」だけで、メッセージの中身は載せません。
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const SECRET = Deno.env.get("WEBHOOK_SECRET") ?? "";
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:example@example.com";

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  if (!SECRET || req.headers.get("x-webhook-secret") !== SECRET) {
    return new Response("forbidden", { status: 403 });
  }
  let p: { room_id?: string; sender_id?: string; kind?: string };
  try { p = await req.json(); } catch { return new Response("bad", { status: 400 }); }
  if (!p.room_id || !p.sender_id) return new Response("bad", { status: 400 });

  const mem = await admin.from("room_members").select("user_id")
    .eq("room_id", p.room_id).neq("user_id", p.sender_id);
  const ids = (mem.data ?? []).map((m: { user_id: string }) => m.user_id);
  if (!ids.length) return new Response("no-recipient");

  const subs = await admin.from("push_subscriptions")
    .select("endpoint,p256dh,auth").in("user_id", ids);

  const body = JSON.stringify({
    title: "そっと報告",
    body: p.kind === "reply" ? "返信が届いています" : "そっと報告が届いています",
    tag: p.room_id,
  });

  let sent = 0;
  await Promise.all((subs.data ?? []).map(async (s: { endpoint: string; p256dh: string; auth: string }) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        body,
        { TTL: 60 * 60 * 24 },
      );
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {
        await admin.from("push_subscriptions").delete().eq("endpoint", s.endpoint);
      }
    }
  }));
  return new Response(`sent ${sent}`);
});

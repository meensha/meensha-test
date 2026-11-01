// Pulls Instagram posts that other people made about Meensha (collab posts that
// show on our profile, plus posts that tag us) and queues them as 'pending'
// rows in `reviews`. Owners approve them in admin.html's Reviews tab; the
// storefront only ever shows 'approved' rows.
//
// Uses the same app_secrets as event-photo-submit (instagram_access_token,
// instagram_business_account_id). Skips quietly when those aren't set.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const GRAPH = "https://graph.facebook.com/v19.0";
const FIELDS = "id,caption,media_type,media_url,thumbnail_url,permalink,timestamp,username";
const MIN_GAP_MS = 60_000;
let lastRun = 0;

type Media = {
  id: string; caption?: string; media_type?: string; media_url?: string;
  thumbnail_url?: string; permalink?: string; timestamp?: string; username?: string;
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (Date.now() - lastRun < MIN_GAP_MS) return json({ ok: true, skipped: "ran under a minute ago" });
  lastRun = Date.now();

  try {
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const token = (await readAppSecret(supabase, "instagram_access_token")) ?? Deno.env.get("INSTAGRAM_ACCESS_TOKEN");
    const igUserId = (await readAppSecret(supabase, "instagram_business_account_id")) ?? Deno.env.get("INSTAGRAM_BUSINESS_ACCOUNT_ID");
    if (!token || !igUserId) return json({ error: "Instagram token / account ID not set yet (admin > Pending Setup)." }, 400);

    const me = await graph(`/${igUserId}?fields=username`, token);
    if (me.error) return json({ error: "Instagram: " + me.error.message }, 502);
    const own = String(me.username ?? "").toLowerCase();

    // Collab posts accepted by us appear in our own /media under the other
    // author's username; /tags covers posts that tag us without a collab.
    const [mediaRes, tagsRes] = await Promise.all([
      graph(`/${igUserId}/media?fields=${FIELDS}&limit=50`, token),
      graph(`/${igUserId}/tags?fields=${FIELDS}&limit=50`, token),
    ]);
    const posts = new Map<string, Media>();
    for (const m of (mediaRes.data ?? []) as Media[]) {
      if (m.username && m.username.toLowerCase() !== own) posts.set(m.id, m);
    }
    for (const m of (tagsRes.data ?? []) as Media[]) {
      if (m.username && m.username.toLowerCase() !== own) posts.set(m.id, m);
    }
    if (!posts.size && mediaRes.error && tagsRes.error) {
      return json({ error: "Instagram: " + mediaRes.error.message }, 502);
    }

    const ids = [...posts.keys()];
    const { data: existing } = ids.length
      ? await supabase.from("reviews").select("ig_media_id").in("ig_media_id", ids)
      : { data: [] as { ig_media_id: string }[] };
    const have = new Set((existing ?? []).map((r) => r.ig_media_id));

    let added = 0;
    for (const m of posts.values()) {
      const image = m.media_type === "VIDEO" ? m.thumbnail_url : m.media_url;
      const photo = image ?? null;
      if (have.has(m.id)) {
        // Instagram image links expire after a few days; keep them fresh.
        await supabase.from("reviews").update({ photo_url: photo }).eq("ig_media_id", m.id);
        continue;
      }
      const { error } = await supabase.from("reviews").insert({
        source: "instagram",
        ig_media_id: m.id,
        ig_permalink: m.permalink ?? null,
        ig_username: m.username ?? null,
        display_name: "@" + m.username,
        review_text: (m.caption ?? "").slice(0, 600),
        photo_url: photo,
        status: "pending",
        created_at: m.timestamp ?? new Date().toISOString(),
      });
      if (!error) added++;
    }
    return json({ ok: true, found: posts.size, added });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});

async function graph(path: string, token: string) {
  const sep = path.includes("?") ? "&" : "?";
  const res = await fetch(`${GRAPH}${path}${sep}access_token=${encodeURIComponent(token)}`);
  return await res.json();
}

async function readAppSecret(supabase: ReturnType<typeof createClient>, key: string): Promise<string | null> {
  const { data } = await supabase.from("app_secrets").select("value").eq("key", key).maybeSingle();
  return data?.value || null;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
}

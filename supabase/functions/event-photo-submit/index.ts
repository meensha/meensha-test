// Records one public event-photo submission (event-photos.html) and, once
// an event has 4 unposted photos, auto-publishes them as an Instagram
// carousel. All the actual auth/gating logic (login required, on/off
// toggle, event date range) lives in the add_event_photo RPC — this
// function is a thin wrapper that adds the one thing an RPC can't do:
// outbound HTTP to the Instagram Graph API.
//
// Required secrets for the Instagram step (optional — submission still
// works and just skips posting if these aren't set yet, same
// graceful-degradation pattern as Resend/RESEND_API_KEY elsewhere):
//   INSTAGRAM_ACCESS_TOKEN, INSTAGRAM_BUSINESS_ACCOUNT_ID
// Supabase auto-provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const CAROUSEL_BATCH_SIZE = 4;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const { token, event_id, photo_url, caption, instagram_handle } = await req.json();
    if (!token || !event_id || !photo_url) return json({ error: "token, event_id, and photo_url are required" }, 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: rpcResult, error: rpcErr } = await supabase.rpc("add_event_photo", {
      p_token: token,
      p_event_id: event_id,
      p_photo_url: photo_url,
      p_caption: caption || null,
      p_instagram_handle: instagram_handle || null,
    });
    if (rpcErr) return json({ error: rpcErr.message }, 500);
    if (!rpcResult?.ok) return json({ error: rpcResult?.error ?? "Could not save photo" }, 400);

    // Best-effort: never let an Instagram hiccup fail the customer's
    // submission — the photo is already saved either way.
    if ((rpcResult.unposted_count ?? 0) >= CAROUSEL_BATCH_SIZE) {
      tryPostCarousel(supabase, event_id).catch(() => {});
    }

    return json({ ok: true });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});

async function tryPostCarousel(supabase: ReturnType<typeof createClient>, eventId: string) {
  const accessToken = Deno.env.get("INSTAGRAM_ACCESS_TOKEN");
  const igUserId = Deno.env.get("INSTAGRAM_BUSINESS_ACCOUNT_ID");
  if (!accessToken || !igUserId) return; // not configured yet — skip silently

  const { data: batch } = await supabase.rpc("get_unposted_event_photos", { p_event_id: eventId, p_limit: CAROUSEL_BATCH_SIZE });
  const photos: { id: string; photo_url: string; instagram_handle?: string; customer_name?: string }[] = batch ?? [];
  if (photos.length < CAROUSEL_BATCH_SIZE) return;

  const { data: event } = await supabase.from("popups").select("title").eq("id", eventId).single();
  // Credit by @handle when given; fall back to the submitter's name rather
  // than dropping them from the caption entirely.
  const credits = [...new Set(
    photos.map((p) => (p.instagram_handle ? "@" + p.instagram_handle.replace(/^@/, "") : p.customer_name)).filter(Boolean),
  )];
  const credit = credits.length ? ` — photos by ${credits.join(", ")}` : "";
  const caption = `From ${event?.title ?? "our event"}${credit}`;

  const graph = "https://graph.facebook.com/v19.0";
  const childIds: string[] = [];
  for (const p of photos) {
    const res = await fetch(`${graph}/${igUserId}/media`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ image_url: p.photo_url, is_carousel_item: true, access_token: accessToken }),
    });
    const data = await res.json();
    if (!res.ok || !data.id) return; // one failed container aborts the whole batch — nothing posted, nothing marked
    childIds.push(data.id);
  }

  const containerRes = await fetch(`${graph}/${igUserId}/media`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ media_type: "CAROUSEL", children: childIds.join(","), caption, access_token: accessToken }),
  });
  const containerData = await containerRes.json();
  if (!containerRes.ok || !containerData.id) return;

  const publishRes = await fetch(`${graph}/${igUserId}/media_publish`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ creation_id: containerData.id, access_token: accessToken }),
  });
  const publishData = await publishRes.json();
  if (!publishRes.ok || !publishData.id) return;

  await supabase.rpc("mark_event_photos_posted", { p_ids: photos.map((p) => p.id), p_instagram_post_id: publishData.id });
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
}

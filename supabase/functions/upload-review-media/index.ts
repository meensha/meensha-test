// Uploads / deletes review media (customer story screenshots + short videos)
// in the locked `review-media` bucket. The bucket has NO storage.objects
// policies, so the only writer is this function using the service role.
//
// Auth: x-admin-session verified with verify_admin_session_for_chatbot (same
// RPC as highlight-comments); only roles owner / super_admin are allowed.
// The file's real type comes from its magic bytes; the declared type must agree.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-admin-session",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const BUCKET = "review-media";
const MAX_IMAGE = 8 * 1024 * 1024;
const MAX_VIDEO = 15 * 1024 * 1024;
const MIN_GAP_MS = 3_000;
let lastRun = 0;

const EXT: Record<string, string> = {
  "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
  "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov",
};

const ascii = (b: Uint8Array, from: number, to: number) => String.fromCharCode(...b.slice(from, to));

// Returns the real MIME type from the first bytes, or null.
function sniff(b: Uint8Array): string | null {
  if (b.length < 12) return null;
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b[0] === 0x89 && ascii(b, 1, 4) === "PNG" && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a) return "image/png";
  if (ascii(b, 0, 4) === "RIFF" && ascii(b, 8, 12) === "WEBP") return "image/webp";
  if (b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3) return "video/webm";
  if (ascii(b, 4, 8) === "ftyp") {
    const brand = ascii(b, 8, 12);
    if (brand === "qt  ") return "video/quicktime";
    if (/^(isom|iso2|iso4|iso5|iso6|mp41|mp42|avc1|M4V |dash)$/.test(brand)) return "video/mp4";
  }
  return null;
}

// Why a file is not acceptable (or null). `declared` is the browser-sent type.
function fileError(declared: string, size: number, head: Uint8Array): string | null {
  if (!(size > 0)) return "Empty file";
  const real = sniff(head);
  // Phones label .mov/.mp4 inconsistently, so any two ftyp-family types agree with each other.
  const ftyp = (t: string) => t === "video/mp4" || t === "video/quicktime";
  if (!real || !(real === declared || (ftyp(real) && ftyp(declared)))) return "Unsupported file type";
  if (real.startsWith("image/") ? size > MAX_IMAGE : size > MAX_VIDEO) return "File too large";
  return null;
}

const URL_RE = /^https:\/\/eglanmhhcccsuhbxywua\.supabase\.co\/storage\/v1\/object\/public\/review-media\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(?:jpg|jpeg|png|webp|mp4|webm|mov))$/;

async function sessionRole(token: string): Promise<string | null> {
  if (!token) return null;
  const url = Deno.env.get("SUPABASE_URL")!, anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  try {
    const res = await fetch(`${url}/rest/v1/rpc/verify_admin_session_for_chatbot`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: anon, Authorization: `Bearer ${anon}` },
      body: JSON.stringify({ p_token: token }),
    });
    if (!res.ok) return null;
    const body = await res.json();
    return body?.role ?? null;
  } catch { return null; }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const role = await sessionRole(req.headers.get("x-admin-session") ?? "");
  if (role !== "owner" && role !== "super_admin") return json({ error: "Unauthorized" }, 401);

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  try {
    if ((req.headers.get("content-type") ?? "").includes("application/json")) {
      const body = await req.json().catch(() => ({}));
      if (body?.action !== "delete") return json({ error: "Bad request" }, 400);
      const m = URL_RE.exec(String(body?.url ?? ""));
      if (!m) return json({ error: "Bad request" }, 400);
      const { error } = await supabase.storage.from(BUCKET).remove([m[1]]);
      return error ? json({ error: "Could not delete" }, 500) : json({ ok: true });
    }

    // Early size guard (multipart overhead allowance); a missing Content-Length is left to the gateway limits.
    const len = Number(req.headers.get("content-length"));
    if (len > MAX_VIDEO + 4096) return json({ error: "File too large" }, 413);
    // Upload: the gap applies only between SUCCESSFUL uploads (failed validation and deletes never consume it).
    if (Date.now() - lastRun < MIN_GAP_MS) return json({ error: "Please wait a few seconds and try again." }, 429);
    const form = await req.formData().catch(() => null);
    const file = form?.get("file");
    if (!(file instanceof File)) return json({ error: "file required" }, 400);
    const head = new Uint8Array(await file.slice(0, 16).arrayBuffer());
    const err = fileError(file.type, file.size, head);
    if (err) return json({ error: err }, 400);

    const type = sniff(head)!;
    const name = `${crypto.randomUUID()}.${EXT[type]}`;
    const { error } = await supabase.storage.from(BUCKET).upload(name, file, {
      contentType: type, cacheControl: "31536000", upsert: false,
    });
    if (error) return json({ error: "Could not upload" }, 500);
    lastRun = Date.now();
    return json({ url: `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/${BUCKET}/${name}` });
  } catch {
    return json({ error: "Upload failed" }, 500);
  }
});

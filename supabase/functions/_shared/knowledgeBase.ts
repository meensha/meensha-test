// Safe, read-only lookup catalog for the three bots' natural-language Q&A.
// The LLM (see askGemini.ts) NEVER writes or runs SQL itself — it only ever
// picks a lookup name + params from this fixed list, and the actual query
// here is a parameterized, whitelisted read. This is the entire security
// boundary: no free-text ever reaches the database as a query.

// deno-lint-ignore no-explicit-any
type SB = any;

export type LookupName = "item_lookup" | "sales_summary" | "low_stock" | "tech_health" | "pnl_summary" | "returns_pending" | "visit_stats";

export interface LookupDef {
  name: LookupName;
  description: string;
  params: Record<string, string>; // param name -> description, for the LLM prompt
}

// India/AU Kiosk bots get stock+price+own-region sales only. MeenshaMonitor
// gets everything, including cross-region and financial data.
export const LOOKUP_CATALOG_REGIONAL: LookupDef[] = [
  { name: "item_lookup", description: "Find stock count and price for a product by name/material/variant", params: { query: "search text, e.g. 'ajrak' or 'kalamkari dupatta'" } },
  { name: "sales_summary", description: "Sales total/count for a time period", params: { period: "'today' | 'week' | 'month'" } },
  { name: "low_stock", description: "Items with 2 or fewer units available", params: {} },
  { name: "returns_pending", description: "Faulty/defective items flagged and awaiting return to the vendor", params: {} },
];

export const LOOKUP_CATALOG_FULL: LookupDef[] = [
  { name: "item_lookup", description: "Find stock count and price for a product by name/material/variant, across both India and Australia", params: { query: "search text, e.g. 'ajrak' or 'kalamkari dupatta'", region: "'india' | 'australia' | 'all' (default all)" } },
  { name: "sales_summary", description: "Sales total/count for a time period, across both regions", params: { period: "'today' | 'week' | 'month'", region: "'india' | 'australia' | 'all' (default all)" } },
  { name: "low_stock", description: "Items with 2 or fewer units available, either region", params: {} },
  { name: "tech_health", description: "Live tech-stack status: website, Supabase, Razorpay, GitHub, with response times and a few key stats", params: {} },
  { name: "pnl_summary", description: "Profit and loss for a period: revenue minus purchases (COGS) minus overheads", params: { period: "'today' | 'week' | 'month'" } },
  { name: "returns_pending", description: "Faulty/defective items flagged and awaiting return to the vendor", params: {} },
  { name: "visit_stats", description: "Storefront visitor counts (page loads) for today and this week", params: {} },
];

function periodStart(period: string): string {
  const now = new Date();
  if (period === "today") return now.toISOString().slice(0, 10);
  if (period === "week") { const d = new Date(now); d.setDate(d.getDate() - 7); return d.toISOString().slice(0, 10); }
  const d = new Date(now); d.setDate(d.getDate() - 30); return d.toISOString().slice(0, 10);
}

async function itemLookup(supabase: SB, params: { query?: string; region?: string }): Promise<string> {
  const q = (params.query || "").trim();
  if (!q) return "No search term given.";
  let query = supabase
    .from("inventory_skus")
    .select("id,name,display_material,display_variant,sale_price_inr,sale_price_aud,india_available,au_available")
    .or(`name.ilike.%${q}%,display_material.ilike.%${q}%,display_variant.ilike.%${q}%`)
    .limit(8);
  if (params.region === "india") query = query.eq("india_available", true);
  if (params.region === "australia") query = query.eq("au_available", true);
  const { data: skus } = await query;
  if (!skus?.length) return `No items matching "${q}".`;
  const ids = skus.map((s: any) => s.id);
  const { data: units } = await supabase.from("inventory_units").select("sku_id,status").in("sku_id", ids);
  const lines = skus.map((s: any) => {
    const avail = (units || []).filter((u: any) => u.sku_id === s.id && u.status === "available").length;
    const regions = [s.india_available && "🇮🇳", s.au_available && "🇦🇺"].filter(Boolean).join(" ");
    return `${s.name}${s.display_variant ? " (" + s.display_variant + ")" : ""} — ${avail} available ${regions} — ₹${s.sale_price_inr || 0}${s.sale_price_aud ? " / A$" + s.sale_price_aud : ""}`;
  });
  return lines.join("\n");
}

async function salesSummary(supabase: SB, params: { period?: string; region?: string }): Promise<string> {
  const period = params.period || "today";
  const from = periodStart(period);
  const region = params.region || "all";
  let query = supabase.from("sales").select("total,source").gte("date", from);
  if (region === "india") query = query.eq("source", "telegram");
  if (region === "australia") query = query.eq("source", "telegram_au");
  const { data: rows } = await query;
  const total = (rows || []).reduce((a: number, r: any) => a + Number(r.total || 0), 0);
  return `${(rows || []).length} sale(s) since ${from}, total ₹${total.toLocaleString("en-IN")} (region: ${region})`;
}

async function lowStock(supabase: SB): Promise<string> {
  const { data: skus } = await supabase.from("inventory_skus").select("id,name").limit(200);
  const { data: units } = await supabase.from("inventory_units").select("sku_id,status");
  const counts: Record<string, number> = {};
  (units || []).forEach((u: any) => { if (u.status === "available") counts[u.sku_id] = (counts[u.sku_id] || 0) + 1; });
  const low = (skus || []).filter((s: any) => (counts[s.id] || 0) <= 2).map((s: any) => `${s.name} — ${counts[s.id] || 0} left`);
  if (!low.length) return "Nothing is low on stock right now.";
  return low.slice(0, 15).join("\n");
}

async function techHealth(supabase: SB): Promise<string> {
  async function timed(fn: () => Promise<boolean>): Promise<{ ok: boolean; ms: number }> {
    const t0 = Date.now();
    try { const ok = await fn(); return { ok, ms: Date.now() - t0 }; } catch { return { ok: false, ms: Date.now() - t0 }; }
  }
  const website = await timed(async () => (await fetch("https://meensha.in")).ok);
  const supa = await timed(async () => { const { error } = await supabase.from("settings").select("key").limit(1); return !error; });
  const razorpay = await timed(async () => {
    const keyId = Deno.env.get("RAZORPAY_KEY_ID"), keySecret = Deno.env.get("RAZORPAY_KEY_SECRET");
    if (!keyId || !keySecret) return false;
    const r = await fetch("https://api.razorpay.com/v1/payments?count=1", { headers: { Authorization: "Basic " + btoa(`${keyId}:${keySecret}`) } });
    return r.ok;
  });
  const github = await timed(async () => { const r = await fetch("https://api.github.com/repos/meensha/meensha-test"); return r.ok || r.status === 403; });

  const [{ count: skuCount }, { count: unitCount }, { count: activeCoupons }] = await Promise.all([
    supabase.from("inventory_skus").select("id", { count: "exact", head: true }),
    supabase.from("inventory_units").select("id", { count: "exact", head: true }).eq("status", "available"),
    supabase.from("coupons").select("id", { count: "exact", head: true }).eq("active", true),
  ]);

  const line = (label: string, r: { ok: boolean; ms: number }) => `${r.ok ? "✅" : "🔴"} ${label} (${r.ms}ms)`;
  return [
    line("Website", website), line("Supabase", supa), line("Razorpay", razorpay), line("GitHub+Pages", github),
    "", `📦 ${skuCount ?? "?"} SKUs, ${unitCount ?? "?"} units in stock, ${activeCoupons ?? "?"} active coupon(s)`,
  ].join("\n");
}

// Single source of truth for "what's pending return to a vendor" — same
// query admin.html's Home dashboard card (H-RETURNS) reads directly, and
// what the 10am digest (returns-pending-digest) sends.
async function returnsPending(supabase: SB): Promise<string> {
  const { data: rows } = await supabase
    .from("inventory_returns_pending")
    .select("qty,reason,flagged_at,sku_id,vendor_uuid")
    .eq("status", "pending")
    .order("flagged_at", { ascending: false });
  if (!rows?.length) return "No faulty items pending return to a vendor right now.";

  const skuIds = [...new Set(rows.map((r: any) => r.sku_id).filter(Boolean))];
  const vendorIds = [...new Set(rows.map((r: any) => r.vendor_uuid).filter(Boolean))];
  const [{ data: skus }, { data: vendors }] = await Promise.all([
    skuIds.length ? supabase.from("inventory_skus").select("id,name").in("id", skuIds) : { data: [] },
    vendorIds.length ? supabase.from("vendors").select("id,name").in("id", vendorIds) : { data: [] },
  ]);
  const skuName = (id: string) => skus?.find((s: any) => s.id === id)?.name || "Unknown item";
  const vendorName = (id: string) => vendors?.find((v: any) => v.id === id)?.name || "Unknown vendor";

  const lines = rows.map((r: any) =>
    `• ${skuName(r.sku_id)} x${r.qty} — ${vendorName(r.vendor_uuid)}${r.reason ? " — " + r.reason : ""} (flagged ${(r.flagged_at || "").slice(0, 10)})`
  );
  return lines.join("\n");
}

async function pnlSummary(supabase: SB, params: { period?: string }): Promise<string> {
  const period = params.period || "week";
  const from = periodStart(period);
  const [{ data: sales }, { data: purchases }, { data: overheads }] = await Promise.all([
    supabase.from("sales").select("total").gte("date", from),
    supabase.from("purchases").select("total").gte("date", from),
    supabase.from("overheads").select("total").gte("date", from),
  ]);
  const revenue = (sales || []).reduce((a: number, r: any) => a + Number(r.total || 0), 0);
  const cogs = (purchases || []).reduce((a: number, r: any) => a + Number(r.total || 0), 0);
  const oh = (overheads || []).reduce((a: number, r: any) => a + Number(r.total || 0), 0);
  const pnl = revenue - cogs - oh;
  return `Since ${from}: Revenue ₹${revenue.toLocaleString("en-IN")}, Purchases ₹${cogs.toLocaleString("en-IN")}, Overheads ₹${oh.toLocaleString("en-IN")} → P&L ₹${pnl.toLocaleString("en-IN")}`;
}

async function visitStats(supabase: SB): Promise<string> {
  const today = new Date().toISOString().slice(0, 10);
  const weekAgo = periodStart("week");
  const [{ count: todayCount }, { count: weekCount }, { count: todayHome }, { count: todayAbout }] = await Promise.all([
    supabase.from("page_views").select("id", { count: "exact", head: true }).gte("created_at", today),
    supabase.from("page_views").select("id", { count: "exact", head: true }).gte("created_at", weekAgo),
    supabase.from("page_views").select("id", { count: "exact", head: true }).gte("created_at", today).eq("page", "home"),
    supabase.from("page_views").select("id", { count: "exact", head: true }).gte("created_at", today).eq("page", "about"),
  ]);
  return `Today: ${todayCount ?? 0} page loads (${todayHome ?? 0} home, ${todayAbout ?? 0} our-story). This week: ${weekCount ?? 0}.`;
}

export async function runLookup(supabase: SB, name: LookupName, params: Record<string, string>): Promise<string> {
  switch (name) {
    case "item_lookup": return itemLookup(supabase, params);
    case "sales_summary": return salesSummary(supabase, params);
    case "low_stock": return lowStock(supabase);
    case "tech_health": return techHealth(supabase);
    case "pnl_summary": return pnlSummary(supabase, params);
    case "returns_pending": return returnsPending(supabase);
    case "visit_stats": return visitStats(supabase);
    default: return "Unknown lookup.";
  }
}

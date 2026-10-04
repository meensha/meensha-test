// Copied verbatim from chatbot/server/synonyms.json (hand-maintained paraphrase
// map for retrieval.ts). Edge Functions bundle statically-imported sibling
// files fine, but a plain .ts const avoids any import-assertion edge cases.
// Keep this in sync with chatbot/server/synonyms.json if that one changes.

export const SYNONYMS: Record<string, string[]> = {
  "qr": ["voucher", "coupon", "scan", "code"],
  "voucher": ["coupon", "code", "qr"],
  "coupon": ["voucher", "code", "discount"],
  "discount": ["coupon", "voucher", "offer"],
  "kiosk": ["pos", "sale", "instore", "walkin"],
  "bot": ["telegram", "shalbot", "ozbot"],
  "telegram": ["bot"],
  "payment": ["checkout", "razorpay", "pay"],
  "checkout": ["payment", "razorpay", "order"],
  "stock": ["inventory", "intake", "units"],
  "inventory": ["stock", "sku", "units"],
  "invoice": ["bill", "receipt"],
  "login": ["auth", "session", "signin"],
  "auth": ["login", "session"],
  "admin": ["role", "permission", "gating"],
  "instagram": ["ig", "social"],
  "sale": ["kiosk", "checkout", "order"],
};

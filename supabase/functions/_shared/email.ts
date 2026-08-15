// Sends a plain-text email via Resend (resend.com — free tier, 3,000
// emails/month, no WhatsApp Business API cost/approval needed). Falls back
// to logging the message if RESEND_API_KEY isn't set yet, so the rest of
// the auth flow stays testable before you've signed up for a provider.
//
// Required secret once ready: RESEND_API_KEY (from resend.com).
// Optional: EMAIL_FROM (defaults to Resend's shared onboarding sender,
// which only works for testing — verify your own domain in Resend and set
// EMAIL_FROM to an address on it before going live).

export async function sendEmail(to: string, subject: string, text: string) {
  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) {
    console.log(`[STUB] Email to ${to}: ${subject}\n${text}`);
    return;
  }
  const from = Deno.env.get("EMAIL_FROM") || "Meensha <onboarding@resend.dev>";
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from, to, subject, text }),
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Email send failed: ${err}`);
  }
}

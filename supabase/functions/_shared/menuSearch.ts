// Lightweight keyword command-palette: typing a plain word like "event" or
// "voucher" (instead of tapping through menus, or asking a natural-language
// question) surfaces the matching menu action(s) as tappable buttons, using
// each bot's real callback_data — tapping one goes straight into that flow,
// same as tapping it from the actual menu would. Checked before the
// natural-language (Gemini) fallback in both bots; falls through to that if
// nothing matches.

export type MenuAction = { keywords: string[]; label: string; callback_data: string };

export function searchMenuActions(actions: MenuAction[], query: string): MenuAction[] {
  const q = query.trim().toLowerCase();
  if (!q || q.length < 2) return [];
  return actions.filter((a) => a.keywords.some((k) => k.includes(q) || q.includes(k)));
}

const GREETINGS = new Set(["hi", "hii", "hiii", "hello", "helo", "hey", "heyy", "yo", "hola", "namaste"]);

export function isGreeting(text: string): boolean {
  return GREETINGS.has(text.trim().toLowerCase());
}

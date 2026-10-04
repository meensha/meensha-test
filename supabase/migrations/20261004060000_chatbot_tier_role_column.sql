-- Closes the "known gap" documented in chatbot/README.md and TODO.md: both
-- Telegram bots' resolveChatbotTier()/resolveChatbotTierAu() currently
-- hardcode 'sales' for every caller because telegram_allowed_users(_au) had
-- no column distinguishing the account owner from any other allowlisted
-- chat_id — just chat_id/label/active.
--
-- Step 1: additive, zero-behavior-change column. DEFAULT 'sales' matches
-- today's hardcoded behavior exactly for every existing row, so this half
-- alone changes nothing until the UPDATEs below run.
ALTER TABLE public.telegram_allowed_users
  ADD COLUMN role text NOT NULL DEFAULT 'sales' CHECK (role IN ('owner', 'sales'));

ALTER TABLE public.telegram_allowed_users_au
  ADD COLUMN role text NOT NULL DEFAULT 'sales' CHECK (role IN ('owner', 'sales'));

-- Step 2: promote the identified owner row(s) to role='owner'.
--
-- Identification (queried live via `supabase db query --linked`, 2026-10-04):
--
--   telegram_allowed_users (India):
--     chat_id 8853893414, label "migrated", active=true — the ONLY row in
--     this table. Since India's allowlist has exactly one account and this
--     repo's own chatbot/README.md + TODO.md already identify that one
--     account as Shalini (the India bot's account owner), this is the row
--     to promote — not a guess among multiple candidates, there is no other
--     candidate on this table.
--
--   telegram_allowed_users_au (Australia):
--     chat_id 8853893414, label "Meensha Fabrics", active=true
--     chat_id 8918326830, label "Meenakshi Ranjan", active=true
--     Two rows. "Meenakshi Ranjan" is an exact name match for Meenakshi, the
--     AU bot's account owner — unambiguous. "Meensha Fabrics" is the same
--     chat_id already promoted above for India (a shared/business-wide
--     contact used for cross-bot broadcasts, confirmed by Dheeraj as having
--     sent a broadcast as "the business's primary owner contact on BOTH
--     bots" earlier today) — not a second, distinct AU owner identity.
--     Per the task's own framing ("give the owners real owner-tier access
--     via THEIR OWN bots"), Meenakshi's own account on her own (AU) bot is
--     the row that gets AU owner-tier access; chat_id 8853893414 keeps the
--     'sales' default on this table and is promoted only on the India table
--     above, where it's Shalini's own bot.
UPDATE public.telegram_allowed_users
  SET role = 'owner'
  WHERE chat_id = '8853893414';

UPDATE public.telegram_allowed_users_au
  SET role = 'owner'
  WHERE chat_id = '8918326830';

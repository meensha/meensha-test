# Kiosk Mode & Coupons — Staff Quick Reference

A plain, day-to-day explanation of how Kiosk mode and coupon codes work when you're using
the Telegram bot to record a sale. For the technical/behind-the-scenes version, see the
admin-tier flow docs — this version sticks to what you actually see and do.

## Recording a sale with Kiosk mode

1. Open the bot and tap **Kiosk mode**.
2. Pick the item(s) the customer is buying — the bot only shows items that are actually in
   stock, with the real current count.
3. Enter the customer's WhatsApp number, then their name.
4. If the customer has a coupon code, enter it here (or it may already be filled in if the
   customer came from a QR code or a Telegram link — just confirm it looks right).
5. Pick how they're paying: Cash, UPI, Razorpay, or Other.
   - **Cash / UPI / Other**: the sale is recorded right away. You'll get an invoice summary
     and a WhatsApp link to send the customer.
   - **Razorpay**: the bot sends you a payment link to forward to the customer. The sale
     itself only gets recorded once they actually pay — if you don't see it in Sales History
     yet, that usually just means payment hasn't landed.
6. After finishing, the bot takes you straight back to the item picker so you can ring up
   the next sale without starting over.

## Using a coupon code

- Type the code exactly as given. If it's wrong, expired, already used, or not valid for
  your region, the bot will tell you why instead of just failing silently.
- A coupon tied to one specific customer only works for that customer's WhatsApp number —
  if a customer tries to use someone else's code, it will be rejected.
- Some codes are public (anyone can use them) and some are locked to one person. You don't
  need to know which in advance — just enter the code and the bot/system will tell you if
  it's valid.
- If a customer scanned a QR code or tapped a Telegram link to get here, their code may
  already be filled in for you — just continue the sale as normal.

## If something looks wrong

If a sale isn't showing up, a coupon won't apply, or stock looks off, flag it to Dheeraj,
Shalini, or Meenakshi rather than re-entering the sale — duplicate entries are harder to
clean up after the fact than a short delay.

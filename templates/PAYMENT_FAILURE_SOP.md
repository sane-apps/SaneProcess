# Payment Failure SOP — Legitimate Cases

When a customer reports a payment that didn't go through but they were (or appear to be) charged.

## Smell Test

Before using this template, the case should pass ALL of these:

1. **Real person** — has a real email, writes like a human, not a throwaway account
2. **Describes the problem clearly** — "I tried to pay and it didn't work" not "give me free stuff"
3. **No order exists on our end** — checked LemonSqueezy API (orders, customers, license-keys) and found nothing
4. **Payment processor gap** — the failure is between their bank/Apple Pay/Google Pay and LemonSqueezy/Stripe, not something we control
5. **First contact** — not someone who's done this before across multiple products

If it doesn't pass the smell test, reply with standard support: "Can you send a screenshot of the charge?" and escalate to the user.

## Procedure

### 1. Verify there's no order

```bash
ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb sales \
  --find-customer-orders --email CUSTOMER_EMAIL --json
```

If an order EXISTS — this is a license delivery issue, not a payment failure. Different SOP.

### 2. Create a 100% discount code

Create the discount in the Lemon Squeezy dashboard, or add a guarded SaneMaster
command before using an API path repeatedly. Do not paste raw vendor API curl
commands into a support session.

### 3. Build the checkout link with discount pre-filled

LemonSqueezy checkout URLs accept `?discount_code=CODE` — the customer just clicks and the code is already applied. Zero friction.

```
https://saneapps.lemonsqueezy.com/checkout/buy/[CHECKOUT_ID]?discount_code=[CODE]
```

| App | Checkout ID | Normal buy link |
|-----|-------------|-----------------|
| SaneBar | `8a6ddf02-574e-4b20-8c94-d3fa15c1cc8e` | https://go.saneapps.com/buy/sanebar |
| SaneClick | `679dbd1d-b808-44e7-98c8-8e679b592e93` | https://go.saneapps.com/buy/saneclick |
| SaneClip | `e0d71010-bd20-49b6-b841-5522b39df95f` | https://go.saneapps.com/buy/saneclip |
| SaneHosts | `83977cc9-900f-407f-a098-959141d474f2` | https://go.saneapps.com/buy/sanehosts |
| SaneSales | `5f7903d4-d6c8-4da4-b3e3-4586ef86bb51` | https://go.saneapps.com/buy/sanesales |

To verify checkout routing, use the app website and `SaneMaster.rb events` /
`SaneMaster.rb downloads` receipts rather than ad hoc raw curls.

### 4. Send the email

Use this template (adapt naturally — don't copy-paste robotically):

---

**Subject:** Re: [their subject]

Hi [NAME],

Thanks for reaching out, and sorry about the checkout trouble.

I checked on my end and the payment didn't come through — it looks like something went wrong between [Apple Pay / their payment method] and the payment processor. If you're seeing a charge, it should be a pending authorization that drops off within a few days. If it doesn't fall off after a week, let me know and I'll help sort it out.

In the meantime, I don't want you stuck waiting — here's a link to get [APP] right now, on me:

[CHECKOUT_LINK_WITH_DISCOUNT_CODE]

If the link gives you any trouble, the code is [CODE] — just enter it at checkout.

If the charge ends up falling off and you love the product, feel free to support your local struggling dev: https://github.com/sponsors/MrSaneApps

Thanks for checking out [APP] — I hope you love it!

— Mr. Sane
https://saneapps.com

---

### 4. Track it

- Discount code name includes customer name + "Payment Issue" for audit trail
- LemonSqueezy shows redemption if/when they use it
- If pending charge doesn't fall off after 7 days and customer follows up, escalate to user

## Voice Notes

- Singular voice only (I/me/my, never we/us/our)
- Warm, direct, human — not corporate support bot
- "should" not "will" — humility over certainty
- Light humor welcome ("support your local struggling dev")
- NEVER say "grab" — use "download", "get", or "update to the latest"
- Close with checkout link so they can easily do the right thing later
- Don't invent problems that don't exist (e.g., don't mention "double-charged" risk)

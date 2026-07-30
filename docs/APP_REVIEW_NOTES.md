# App Review Information — Notes field

Paste the block below into **App Store Connect → app version → App Review
Information → Notes**. Apple's own review tips ask for the app's concept and
business model, and for a way to see the full experience without doing setup
work. The 2026-07-23 submission left this field empty.

There is no account system, so no demo credentials are needed — but say that
explicitly rather than leaving the reviewer to discover it.

---

**Concept.** Argus is an offline-first crypto portfolio tracker. You enter what
you hold — by typing it, pasting a public wallet address, or importing an
exchange CSV — and Argus values it at live prices and computes cost basis and
realized gains (FIFO / LIFO / HIFO).

**Business model.** Free, no ads, no in-app purchases, no subscription, no
accounts.

**No sign-in required.** There is no login, no server, and no user account, so
there are no demo credentials to provide. Every holding is stored locally on the
device only. Nothing is uploaded.

**What you see on launch, with zero setup.** The first screen shows live market
prices for the largest coins by market cap, fetched from CoinGecko's public API.
No data entry is needed to see the app working. Tapping any coin opens the "add
holding" sheet pre-filled with that asset.

**To see the full experience in under a minute:**

1. Launch the app — the "Market today" card populates with live prices.
2. Tap **BTC** in that list. The add-holding sheet opens with Bitcoin selected
   and today's price filled in.
3. Enter a quantity (e.g. `0.5`) and tap **Save**.
4. The portfolio screen now shows net worth, the holding, its value, and the
   realized-gains card. Tap the holding for its detail screen: price history
   chart, per-coin news, and a price-alert toggle.
5. Optional: **＋ → Import from wallet**, paste any public Ethereum address, and
   Argus fills in that address's balances across chains.

**Network dependency.** Prices come from CoinGecko's public API. If that request
fails or is rate-limited, the app now says so on screen with a Retry button — it
does not render prices as zero or as an empty portfolio.

**Permissions.** Notifications are requested only if the user enables a price
alert, and only then. Background App Refresh is used solely to re-check enabled
price alerts.

**Device support.** iPhone only (`TARGETED_DEVICE_FAMILY = 1`); tested on
physical hardware via TestFlight.

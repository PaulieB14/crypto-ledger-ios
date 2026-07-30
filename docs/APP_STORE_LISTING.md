# App Store listing — Argus Crypto Tracker

Copy/paste into App Store Connect → your app → (Version) → App Information &
Product Page. Character limits noted; all fields below are within them.

---

## App Name (≤30)
`Argus Crypto Tracker`

## Subtitle (≤30)
`Track crypto. Own your data.`

*Alternates:* `Your net worth, on device` · `Crypto net worth, privately`

## Promotional Text (≤170, editable anytime without review)
`A private crypto tracker with a live net-worth chart, wallet import across 5 chains, cost-basis math, and price alerts — no account, all on your device.`

## Keywords (≤100, comma-separated, no spaces after commas)
`portfolio,bitcoin,ethereum,wallet,networth,cost basis,price alert,holdings,defi,coin,gains,ledger`

*(The app name is already indexed, so `crypto` and `tracker` were dropped from
here — repeating name terms in keywords buys nothing and cost 15 characters.
`gains` and `ledger` use the freed space. 96/100.)*

## Description (≤4000)
Argus is a crypto portfolio tracker for people who want to see exactly what
they hold — without handing their financial data to anyone.

Everything lives on your device. No account, no sign-up, no tracking, no ads.

**See your net worth, honestly**
A clean net-worth chart built from real price history and your own transactions
— never faked. Cash and crypto broken out at a glance, with gains and losses
shown only where they belong.

**Add what you hold — three ways, easiest first**
• Add a holding — just type how much of a coin you own.
• Import from a wallet — paste a public address and Argus pulls your balances
  across Ethereum, Base, Arbitrum, Polygon, and Optimism (read-only; it never
  asks for a seed phrase or key).
• Import a CSV — bring your full history from an exchange.

**Real cost-basis math**
Log buys and sells with fees, and Argus tracks your true cost basis and
realized gains — switch between FIFO, LIFO, and HIFO to see how it changes.

**Prices, charts, and news for every coin**
Live prices and logos for 1,000+ coins, a price chart on each holding, and
per-coin news headlines.

**Price alerts**
Set a target on any coin and Argus notifies you when it's crossed. Alerts are
checked in the background — iOS decides when that runs, so they arrive shortly
after a move rather than to the second — and again the moment you open the app.
Everything is evaluated on your device, so no server ever sees your targets.

**Private by design**
Your holdings never leave your phone. Argus fetches only public market data,
public headlines, and — if you choose — public wallet balances. There are no
accounts and nothing to sign in to.

Argus is a tracker, not an exchange: it holds no funds, places no trades, and
never touches your keys.

## What's New (first version)
`First release. Track your crypto net worth privately: add holdings, import a
wallet or CSV, cost-basis math with fees, per-coin charts and news, and price
alerts — all on your device.`

---

## Metadata
- **Primary category:** Finance
- **Secondary category:** Utilities (optional)
- **Age rating:** 4+ (no trading, no custody, no objectionable content — it's a tracker)
- **Price:** Free (recommended for v1) — or $0.99 if you want the "will anyone pay" signal
- **Privacy policy URL:** ⚠️ **not yet published.** `docs/privacy.html` exists
  only in this repo, the repo is private, and GitHub Pages is not enabled — so
  every candidate URL 404s today. App Store Connect requires a reachable
  privacy policy; a dead link there is both a compliance failure and a strong
  "unfinished" signal. Publish it first (Vercel static deploy, or make the repo
  public and turn on Pages), then paste the live URL.
- **Support URL:** same problem — needs a real, reachable page, not the README
  of a private repo.
- **Privacy "nutrition label" answers:** Data Not Collected — no accounts, no
  analytics, no server. Note for honesty's sake: using wallet import sends the
  address you paste to public block explorers, and prices/news come from
  CoinGecko and Google News. None of it is collected *by us* and none of it is
  linked to an identity, which is why "Data Not Collected" is the right answer —
  but the description says so plainly rather than leaving it implied.

## Screenshots — recapture before any future submission

None are checked into this repo, so there's no record of what was uploaded on
2026-07-23. Anything captured before commit `08bafa7` shows either the empty
onboarding form or the **sample-data** portfolio — i.e. the product page itself
may have been advertising fabricated holdings.

Capture fresh ones from the current build: the "Market today" card on first
launch, a real portfolio with the net-worth chart, a holding detail with its
price chart, and the alert sheet.

# App Store listing draft (next version after 1.0.4)

Paste into App Store Connect. Counts are on the limit lines.
The public support site is `docs/index.html` and `docs/privacy.html`.
GitHub Pages also publishes every other file in this folder.

No em dashes in the copy below.

Live page checked: https://apps.apple.com/us/app/argus-crypto-tracker/id6793740171
Subtitle today: `Track crypto. Own your data.` One rating (5.0).

Another app is named Argus Portfolio Tracker. The subtitle has to carry
words the name does not already index (`crypto` and `tracker` are in the
name) and has to say what that other name does not: private, and no account.
Do not claim anything about the other app. Say what this one is.

Do not upload until `MARKETING_VERSION` in
`.github/workflows/testflight.yml` is higher than 1.0.4. That train is the
live release. Apple rejects further uploads to a closed train.

## Name (30)

`Argus Crypto Tracker` (21)

Leave it. Renaming now would throw away the listing, the one rating, and the
link people already have.

## Subtitle (30)

`Private portfolio. No account` (29)

Search words the name does not have: portfolio, private, account.
The line also splits this app from a generic "portfolio tracker": no account,
data on the phone. The live subtitle can stay only if you would rather not
touch a line that is already approved. It does not say portfolio, and it does
not say no account.

## Promotional Text (170)

`A private crypto portfolio with no account. Net worth and cost basis stay on your phone. Hide dust balances and open a free Bitcoin cycle dashboard.` (148)

Promotional text can change without a new review. Use it the day the build
goes live, even before the description is approved, if the timing works.

## Keywords (100)

`bitcoin,ethereum,wallet,networth,cycle,halving,cost basis,price alert,holdings,defi,staking,gains` (97)

Comma-separated, no space after a comma. `portfolio`, `private`, and
`account` are left out on purpose: the subtitle already indexes them.
`crypto`, `tracker`, and `argus` are left out because the name indexes them.
`cycle`, `halving`, and `staking` are the terms this version adds.

## Description (4000)

Paste from the first line of the block through "never touches your keys."
The first three lines are what the store shows before More. Each is short
enough to stay on one line on an iPhone. Do not paste this note.

No account. Your crypto stays on your phone.
Net worth and cost basis, across 12 chains.
Hide dust. Open the Bitcoin cycle dashboard.

SEE YOUR NET WORTH
A chart from real price history and your own records. Cash and crypto are broken out. Gains and losses show only where they belong. The change under the total is the change in tracked value, including holdings you added. It is not a performance claim.

HIDE SMALL BALANCES
A wallet import can include dust. Hide holdings under $1, $10, $100, or an amount you choose. The list says how many are hidden. One tap shows them again. Your net worth still counts every holding. A coin with no price stays visible.

MARKET CYCLE
Open a free public Bitcoin cycle dashboard inside the app. Score from 0 to 100, 30+ indicators, days from the top, and the halving countdown. It is a reference, separate from your portfolio. Argus does not send your holdings to it.

ADD WHAT YOU HOLD
- Add a holding. Type how much of a coin you own.
- Import from a wallet. Paste a public address. Argus reads balances on Ethereum, Base, Arbitrum, Polygon, Optimism, Scroll, zkSync Era, Gnosis, Celo, Unichain, and Mode, plus native Plasma. Read only. It never asks for a seed phrase or a private key. Coins are matched by contract, not by ticker, so a look-alike cannot pass as the real coin.
- Import a CSV. Bring history across as date, type, asset, quantity, price.
- Add a loan by hand, or import one.

COST BASIS
Log buys, sells, and fees. Switch FIFO, LIFO, and HIFO. The split between realized and unrealized changes. What you own does not.

STAKING AND LOANS
StakeWise vaults, Livepeer (LPT), and The Graph (GRT) count toward net worth and stay distinct from the liquid coin. Loans from Aave, Spark, Compound, Fluid, and Morpho count as collateral minus debt, with health factor. Any other loan can be added by hand.

PRICES, CHARTS, ALERTS
Live prices for the top coins, a chart on each holding (week, month, three months), and headlines for that coin. Set a price alert. The check runs on your phone. No server sees the target.

PRIVATE BY DESIGN
Holdings stay on this iPhone. Lock the app with Face ID or your device passcode. No account, no sign-up, no tracking, no ads. Argus fetches public market data, public headlines, and, only if you ask, public wallet balances.

Argus is a tracker, not an exchange. It holds no funds, places no trades, and never touches your keys.

## What's New

`Hide balances under $1, $10, $100, or your own amount. Your total still includes them. Market Cycle opens a free Bitcoin cycle dashboard inside the app. Clearer type and labels.` (177)

Do not mention the rating prompt. It is a system dialog, not a feature.

## Screenshot plan

Six frames. Same layout on every frame so the set reads as one brand, not six ads.

- Canvas: 1320 x 2868 (6.9-inch iPhone, the size App Store Connect asks for).
- Background: `#0B0B0D` full bleed. That is the app's dark paper and the icon's near-black.
- Headline: one short benefit line, SF Pro Bold, about 72pt, color `#F5B13C` (the dark-mode amber), centered, safe margin at least 80pt from the top and the sides. No second line of marketing copy.
- Device: one iPhone frame, centered under the headline, screenshot in dark mode so the bezel sits on the same black. Same frame, same size, same vertical position on all six.
- Status bar: 9:41, full battery, no personal notifications.
- Data: demo amounts you type in by hand (for example 0.50 BTC, 2 ETH, and a few coins under $1). Not a real wallet, not a customer's holdings, and not the old sample-portfolio mode. The app does not ship with fake data. The screenshots are staged.

`.github/workflows/app-store-screenshots.yml` captures these on a Mac runner from a Debug simulator build launched with `-ArgusDemoScreenshots`. That workflow does not upload to TestFlight. Appearance is forced to Dark for those launches only.

1. Headline on the image: `No account. On your phone.`
   Screen: portfolio. Net worth, the chart, and the Market Cycle card under it.
2. Headline on the image: `Hide the dust.`
   Screen: Holdings with the filter on "Hide under $10" and the line "N hidden under $10".
3. Headline on the image: `One tap shows it all.`
   Screen: the same list after tapping Show all. Small rows are back. The line reads "Showing N under $10".
4. Headline on the image: `Know what you paid.`
   Screen: a holding (BTC). Price, chart, cost, and unrealized gain.
5. Headline on the image: `See the Bitcoin cycle.`
   Screen: the Market Cycle card, then the in-app Safari page of the public dashboard (score, indicators, halving). Crop so it is clearly still inside Argus.
6. Headline on the image: `Paste an address. Read only.`
   Screen: Import from wallet, address field visible, copy that it never asks for a seed phrase.

App Store caption under each shot: the same headline as the image. Do not add a second slogan.

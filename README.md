# Argus

A crypto portfolio tracker for iPhone that keeps your financial data on your phone.

**[Download on the App Store](https://apps.apple.com/app/id6793740171)** · no account, no sign-up, no tracking, no ads.

Paste a public wallet address and Argus finds what you hold across 12 chains. Or log
trades by hand and it tracks real cost basis. Everything is stored on the device;
nothing is uploaded.

---

## What it does

- **Net worth over time** — reconstructed from your own ledger against real price
  history, not a number the app invents.
- **Import from a wallet** — paste a public address, get your balances across 12
  chains. Read-only: it never asks for a seed phrase or private key.
- **Real cost-basis math** — buys, sells and fees produce true cost basis and realized
  gains. Switch between FIFO, LIFO and HIFO and watch the split change.
- **CSV import** — bring history across as `date, type, asset, quantity, price`.
- **Price alerts** — local notifications, delivered on-device. No server ever sees them.
- **Per-coin news and prices** for the top 1,000 coins.

## Wallet import, and why it is careful

Token symbols are set by whoever deploys the contract, so a real wallet is full of
impersonators. One mainnet address we test against holds **7,942 tokens, 6,687 of them
ERC-20**, topped by airdropped junk minted at 10⁵⁹ units — and **two separate contracts
both calling themselves USDC**.

Argus identifies tokens by **contract address**, never by symbol, and prices them from
the explorer's own per-contract market rate. That rate exists only for contracts the
explorer can match to a real market feed, so it doubles as the counterfeit check: of the
two "USDC" contracts above, only the genuine one has one.

Holdings are then merged on resolved identity, so native ETH across eight L2s is a single
row rather than eight, while a counterfeit — which resolves to nothing — can never merge
into a real position.

Anything it cannot identify is left out rather than guessed at, and the count is shown so
nothing disappears silently.

### Chains

Full ERC-20 enumeration via public Blockscout instances, no API key:

Ethereum · Base · Arbitrum · Polygon · Optimism · Scroll · zkSync Era · Gnosis · Celo ·
Unichain · Mode

**Plasma** is native XPL only, over its public RPC. It has no public Blockscout, and its
explorer is Etherscan V2 whose token-balance endpoint is paid on every chain — so there
is no keyless way to enumerate Plasma tokens yet. An RPC genuinely cannot list a wallet's
holdings; there is no index to query. Tokens follow if a Blockscout instance appears.

Nothing secret ships in the binary. That is a deliberate constraint, not an oversight: an
API key embedded in an iOS app is extractable by anyone who unzips it, and its rate limit
would be shared across every user.

## Decisions worth knowing before you extend this

**`LedgerEntry`, not `Transaction`.** SwiftUI and StoreKit both export a `Transaction`
type. Naming yours the same means disambiguating in every file that imports either.

**Fees are their own entries.** A trade is several entries sharing a `groupID` (USD out,
BTC in, fee out) rather than one entry with a `fee` field. This kills the "is the fee
already reflected in the quantity?" ambiguity that produces most balance drift.

**Every quantity is a `Decimal` serialized as a string.** `JSONDecoder` routes JSON
numbers through `Double` before reaching `Decimal`, and SQLite's `REAL` is a double.
Either one silently corrupts 18-decimal token amounts. There is a test for this.

The same trap bites outside the ledger: parsing an `eth_getBalance` hex result into
`UInt64` overflows at ~18 coins. Balances accumulate into `Decimal`.

**Unmatched transfers break reconciliation on purpose.** When a transfer has no
counterpart, `snapshot.reconciles` goes false and the entry lands in the review queue
rather than being guessed at as a sale. A visible discrepancy beats a confident wrong
number — the principle the whole wallet-import path is built on.

**Lots are pooled per asset, not per wallet.** That is how most consumer trackers behave,
and it keeps matched transfers free. Note that Rev. Proc. 2024-28 moved US taxpayers to
per-wallet basis tracking for dispositions from 2025 onward, so this is a v1
simplification to revisit before shipping tax exports. `accountID` is on every entry, so
the change is the key of the `lots` dictionary and nothing else.

**Net worth is method-invariant; the realized/unrealized split is not.** The fixture is
built so the same BTC sale is long-term under FIFO (+$8,400) and short-term under HIFO
(+$3,000). Property tests assert the invariant across all three methods.

## Layout

| Path | What lives there |
|---|---|
| `App/` | SwiftUI app — views, wallet import, price catalog, alerts |
| `LedgerCore/` | The engine: immutable `LedgerEntry` facts → `PortfolioEngine.snapshot`. Pure, testable, no UI |
| `docs/` | Privacy policy and support pages (GitHub Pages) |
| `.github/workflows/` | `testflight.yml` ships to TestFlight; `ios-build.yml` compiles on push |

## Development

Xcode is not required for most work. `MacPreview/` is a SwiftPM harness whose sources are
**symlinks** to `App/*.swift`, so it compiles the real app against the macOS SDK and
catches nearly every Swift error in seconds:

```bash
cd MacPreview && swift build      # type-check the real sources
swift run                         # macOS window running the real NetWorthView
```

It also runs headless against a live address, which is how the import path is tested
without a simulator:

```bash
ARGUS_HARNESS=0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045 swift run
```

Two gaps: it does not compile `App/CryptoLedgerApp.swift` (the iOS `@main`, including the
BGTask delegate) or any `#if os(iOS)` branch, and a newly added `App/*.swift` needs
symlinking in or the harness silently misses it. iOS-only concurrency problems surface
only at CI archive.

**Shipping:** `gh workflow run testflight.yml`. The build number auto-increments from
`github.run_number`; the marketing version is the `MARKETING_VERSION` env var at the top
of the workflow. Bump it for every release — once Apple approves a version it closes that
train and rejects further uploads to it.

## Known limits

- Prices and identity cover the top 1,000 coins by market cap; holdings outside that are
  recognised but shown without a value.
- Plasma is native-balance only (see above).
- Cost basis is pooled per asset, not per wallet.
- Wallet import reads public explorers, so it inherits their coverage and uptime.

## License

MIT

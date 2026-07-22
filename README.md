# CryptoLedger — scaffold

Event-sourced crypto portfolio ledger. No network, no keys, no accounts.

## Layout

```
LedgerCore/          Swift package. Pure Foundation. Builds and tests anywhere.
  LedgerEntry        The immutable fact. One entry = one asset moving in one account.
  PortfolioSource    Protocol every provider conforms to. FixtureSource is the only impl.
  TransferMatcher    Pairs wallet-to-wallet moves so they don't book as sales.
  LotEngine          FIFO / LIFO / HIFO, holding period, realized gains.
  PortfolioEngine    Folds everything into a PortfolioSnapshot.

App/                 SwiftUI. Add to a new iOS App target in Xcode.
Persistence/         GRDB. Add only when you outgrow in-memory.
```

## Run the tests first

```bash
cd LedgerCore && swift test
```

That is the whole point of this scaffold: the accounting is correct against
known answers before any API key exists in the codebase. The expected values in
`KnownAnswerTests` were computed by an independent reference implementation.
**If a test fails, the code is wrong, not the number.**

## Generating the Xcode project

```bash
brew install xcodegen
xcodegen generate
xcrun simctl list devices available | head
```

If no simulators are listed, run `xcodebuild -downloadPlatform iOS`.

The `.xcodeproj` is generated from `project.yml` and is gitignored on purpose.
Regenerate it rather than committing it.

Add GRDB (`https://github.com/groue/GRDB.swift`) and the `Persistence/` files
only when you need data to survive a relaunch. The scaffold works without it.

## Decisions worth knowing before you extend this

**`LedgerEntry`, not `Transaction`.** SwiftUI and StoreKit both export a
`Transaction` type. Naming yours the same means disambiguating in every file
that imports either.

**Fees are their own entries.** A trade is several entries sharing a `groupID`
(USD out, BTC in, fee out) rather than one entry with a `fee` field. This kills
the "is the fee already reflected in the quantity?" ambiguity that produces most
balance drift.

**Every quantity is a `Decimal` serialized as a string.** `JSONDecoder` routes
JSON numbers through `Double` before reaching `Decimal`, and SQLite's `REAL` is
a double. Either one silently corrupts 18-decimal token amounts. There is a test
for this.

**Unmatched transfers break reconciliation on purpose.** When a transfer has no
counterpart, `snapshot.reconciles` goes false and the entry lands in the review
queue rather than being guessed at as a sale. A visible discrepancy beats a
confident wrong number.

**Lots are pooled per asset, not per wallet.** That is how most consumer trackers
behave, and it keeps matched transfers free. Note that Rev. Proc. 2024-28 moved
US taxpayers to per-wallet basis tracking for dispositions from 2025 onward, so
this is a v1 simplification you will need to revisit before shipping tax exports.
`accountID` is on every entry, so the change is to the key of the `lots`
dictionary and nothing else.

**Net worth is method-invariant; the realized/unrealized split is not.** The
fixture is built so the same BTC sale is long-term under FIFO (+$8,400) and
short-term under HIFO (+$3,000). There are property tests asserting the
invariant across all three methods.

## Simulator notes

Screenshots of a Claude-driven simulator are retained under your normal
conversation settings, so keep real credentials off it. The fixture source
exists so you never need them during development.

Secure Enclave is emulated in software in the simulator, and Face ID is a menu
toggle. When you add Keychain storage for exchange keys, that module has to be
verified on physical hardware from Xcode — everything in `LedgerCore` is fine in
the simulator.

## Next

1. `ManualEntrySource` — the ledger already supports it, it needs a form.
2. CSV import with per-exchange column mappers.
3. `TokenAPISource` against `token-api.thegraph.com/v1/evm/transfers`, which
   returns transfers with USD value at execution time — the exact shape
   `LedgerEntry` wants.
4. Spam filtering before any real address touches the UI.
5. Coinbase OAuth, read-only scopes, Keychain, device-only.

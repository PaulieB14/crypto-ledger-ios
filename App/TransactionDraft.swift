import Foundation
import LedgerCore

/// A transaction the user is entering, before it becomes immutable `LedgerEntry`
/// facts. Keeping the draft separate from the ledger keeps the accounting pure:
/// the form collects intent, `makeEntries()` translates it into the one-fact-
/// per-movement entries the engine folds over.
struct TransactionDraft {

    enum Kind: String, CaseIterable, Identifiable {
        case balance, buy, sell, receive, deposit

        var id: String { rawValue }

        /// Kinds offered in the "Add transaction" segmented picker. `balance` is
        /// the simplest, separate on-ramp and gets its own focused sheet, so it
        /// isn't listed here.
        static var transactionKinds: [Kind] { [.buy, .sell, .receive, .deposit] }

        var title: String {
            switch self {
            case .balance: "I own"
            case .buy: "Buy"
            case .sell: "Sell"
            case .receive: "Receive"
            case .deposit: "Add cash"
            }
        }

        var subtitle: String {
            switch self {
            case .balance: "Enter how much you already hold — valued at today's price"
            case .buy: "Spend cash to acquire crypto"
            case .sell: "Dispose crypto for cash"
            case .receive: "Crypto arrived (airdrop, transfer, reward)"
            case .deposit: "Fund your account with USD"
            }
        }

        var icon: String {
            switch self {
            case .balance: "chart.pie.fill"
            case .buy: "arrow.down.left.circle.fill"
            case .sell: "arrow.up.right.circle.fill"
            case .receive: "tray.and.arrow.down.fill"
            case .deposit: "dollarsign.circle.fill"
            }
        }

        var isCash: Bool { self == .deposit }
        var isCrypto: Bool { !isCash }
        /// Buy/sell always need a price; receive and balance are optional (cost basis).
        var requiresPrice: Bool { self == .buy || self == .sell }
    }

    var kind: Kind = .buy
    var asset: String = "BTC"
    var quantityText: String = ""
    var priceText: String = ""
    var feeText: String = ""
    var account: String = "Manual"
    var date: Date = .now

    var quantity: Decimal? { UserNumber.decimal(quantityText) }
    var price: Decimal? { UserNumber.decimal(priceText) }
    /// Trading fee in USD. Blank means none.
    var fee: Decimal { UserNumber.decimal(feeText) ?? 0 }

    /// Canonical symbol used for the ledger + price lookups. Uppercasing here is
    /// what keeps a typed `btc` from mismatching CoinGecko's `BTC` and showing a
    /// phantom "no price" review item.
    var normalizedAsset: String { asset.trimmingCharacters(in: .whitespaces).uppercased() }

    var isValid: Bool {
        guard let q = quantity, q > 0 else { return false }
        if kind.requiresPrice { return (price ?? 0) > 0 }
        return true
    }

    /// Rough USD value of this draft, for a live preview in the form. For a buy
    /// this is the total spent (price × qty + fee); for a sell it's what you
    /// net after the fee.
    var estimatedUSD: Decimal? {
        switch kind {
        case .deposit:
            return quantity
        case .buy:
            guard let q = quantity, let p = price else { return nil }
            return q * p + fee
        case .sell:
            guard let q = quantity, let p = price else { return nil }
            return q * p - fee
        case .receive, .balance:
            guard let q = quantity, let p = price else { return nil }
            return q * p
        }
    }

    /// Label for the estimate row — the number means different things per kind.
    var estimateLabel: String {
        switch kind {
        case .buy: fee > 0 ? "Total cost (incl. fee)" : "Total cost"
        case .sell: fee > 0 ? "You'll receive (after fee)" : "You'll receive"
        default: "Estimated value"
        }
    }

    // MARK: - Translation to ledger facts

    /// The immutable entries this draft produces. Buys/sells create both the
    /// crypto leg and its matching USD leg (shared `groupID`) so cash stays
    /// correct automatically.
    func makeEntries() -> [LedgerEntry] {
        let ref = "manual-\(UUID().uuidString)"
        let asset = normalizedAsset
        let q = quantity ?? 0
        let p = price ?? 0

        func entry(_ assetID: String, _ qtyDelta: Decimal, _ k: EntryKind,
                   _ unit: Decimal?, group: String? = nil) -> LedgerEntry {
            LedgerEntry(
                sourceID: "manual",
                externalRef: "\(ref)-\(assetID)-\(k.rawValue)",
                timestamp: date,
                accountID: account,
                assetID: assetID,
                qtyDelta: qtyDelta,
                kind: k,
                unitPriceUSD: unit,
                groupID: group)
        }

        switch kind {
        case .buy:
            // A fee paid to acquire is part of what the coins cost you, so it
            // rides in the lot's unit basis: total spent = price × qty + fee,
            // and the same amount leaves cash.
            let totalCost = q * p + fee
            let unitCost = q > 0 ? totalCost / q : p
            return [entry(asset, q, .buy, unitCost, group: ref),
                    entry("USD", -totalCost, .withdrawal, 1, group: ref)]
        case .sell:
            // A fee on disposal reduces proceeds — and therefore realized gain.
            let net = q * p - fee
            let unitProceeds = q > 0 ? net / q : p
            return [entry(asset, -q, .sell, unitProceeds, group: ref),
                    entry("USD", net, .deposit, 1, group: ref)]
        case .receive:
            // Acquisition at the given cost (or zero-cost if left blank).
            return [entry(asset, q, .airdrop, price)]
        case .balance:
            // "I already hold this much." Priced at today's spot so cost basis
            // equals current value and unrealized P&L starts at zero — honest
            // when the real purchase price is unknown.
            return [entry(asset, q, .airdrop, price)]
        case .deposit:
            return [entry("USD", q, .deposit, 1)]
        }
    }

    /// When the asset has no market price yet, seed one so the new holding
    /// shows a value instead of "No price".
    var spotSeed: (asset: String, price: Decimal)? {
        guard kind.isCrypto, let p = price, p > 0 else { return nil }
        return (normalizedAsset, p)
    }
}

/// Common assets offered in the picker (users can still type any symbol).
enum AssetCatalog {
    static let common = ["BTC", "ETH", "SOL", "GRT", "USDC", "XRP", "DOGE", "ADA", "AVAX", "LINK"]

    /// A stable accent color per symbol, for the badge.
    static func hue(for symbol: String) -> Double {
        let sum = symbol.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(sum % 360) / 360.0
    }
}

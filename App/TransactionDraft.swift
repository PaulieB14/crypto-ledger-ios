import Foundation
import LedgerCore

/// A transaction the user is entering, before it becomes immutable `LedgerEntry`
/// facts. Keeping the draft separate from the ledger keeps the accounting pure:
/// the form collects intent, `makeEntries()` translates it into the one-fact-
/// per-movement entries the engine folds over.
struct TransactionDraft {

    enum Kind: String, CaseIterable, Identifiable {
        case buy, sell, receive, deposit

        var id: String { rawValue }

        var title: String {
            switch self {
            case .buy: "Buy"
            case .sell: "Sell"
            case .receive: "Receive"
            case .deposit: "Add cash"
            }
        }

        var subtitle: String {
            switch self {
            case .buy: "Spend cash to acquire crypto"
            case .sell: "Dispose crypto for cash"
            case .receive: "Crypto arrived (airdrop, transfer, reward)"
            case .deposit: "Fund your account with USD"
            }
        }

        var icon: String {
            switch self {
            case .buy: "arrow.down.left.circle.fill"
            case .sell: "arrow.up.right.circle.fill"
            case .receive: "tray.and.arrow.down.fill"
            case .deposit: "dollarsign.circle.fill"
            }
        }

        var isCash: Bool { self == .deposit }
        var isCrypto: Bool { !isCash }
        /// Buy/sell always need a price; receive is optional (cost basis).
        var requiresPrice: Bool { self == .buy || self == .sell }
    }

    var kind: Kind = .buy
    var asset: String = "BTC"
    var quantityText: String = ""
    var priceText: String = ""
    var account: String = "Manual"
    var date: Date = .now

    var quantity: Decimal? { Decimal(string: quantityText.trimmingCharacters(in: .whitespaces)) }
    var price: Decimal? { Decimal(string: priceText.trimmingCharacters(in: .whitespaces)) }

    var isValid: Bool {
        guard let q = quantity, q > 0 else { return false }
        if kind.requiresPrice { return (price ?? 0) > 0 }
        return true
    }

    /// Rough USD value of this draft, for a live preview in the form.
    var estimatedUSD: Decimal? {
        switch kind {
        case .deposit: quantity
        case .buy, .sell, .receive:
            if let q = quantity, let p = price { q * p } else { nil }
        }
    }

    // MARK: - Translation to ledger facts

    /// The immutable entries this draft produces. Buys/sells create both the
    /// crypto leg and its matching USD leg (shared `groupID`) so cash stays
    /// correct automatically.
    func makeEntries() -> [LedgerEntry] {
        let ref = "manual-\(UUID().uuidString)"
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
            return [entry(asset, q, .buy, p, group: ref),
                    entry("USD", -(q * p), .withdrawal, 1, group: ref)]
        case .sell:
            return [entry(asset, -q, .sell, p, group: ref),
                    entry("USD", q * p, .deposit, 1, group: ref)]
        case .receive:
            // Acquisition at the given cost (or zero-cost if left blank).
            return [entry(asset, q, .airdrop, price)]
        case .deposit:
            return [entry("USD", q, .deposit, 1)]
        }
    }

    /// When the asset has no market price yet, seed one so the new holding
    /// shows a value instead of "No price".
    var spotSeed: (asset: String, price: Decimal)? {
        guard kind.isCrypto, let p = price, p > 0 else { return nil }
        return (asset, p)
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

import Foundation

/// One account's share of a pooled position.
///
/// This is *provenance*, not a per-account cost basis. Lots pool across accounts
/// (see `LotEngine`), so this only answers "where did these units arrive from",
/// which is what tells staked ETH apart from wallet ETH on screen.
public struct AccountQty: Identifiable, Hashable, Sendable {
    public let accountID: String
    public let qty: Decimal
    public var id: String { accountID }

    /// "38.8319 StakeWise Genesis Vault" — compact enough for a caption line.
    public var shortLabel: String {
        "\(qty.formatted(.number.precision(.fractionLength(0...4)))) \(accountID)"
    }
}

public struct Position: Identifiable, Hashable, Sendable {
    public let assetID: String
    public let qty: Decimal
    public let costBasisUSD: Decimal
    public let spotUSD: Decimal?
    /// Where this position's units came from, when they came from more than one
    /// place. Empty when everything shares one account — and also empty when the
    /// parts stop summing to the whole, because sub-rows that do not add up to
    /// the row above them read as a bug rather than as information.
    public let byAccount: [AccountQty]

    public var id: String { assetID }
    public var marketValueUSD: Decimal? { spotUSD.map { qty * $0 } }
    public var unrealizedUSD: Decimal? { marketValueUSD.map { $0 - costBasisUSD } }
}

public struct PortfolioSnapshot: Sendable {
    public let asOf: Date
    public let method: CostBasisMethod

    public let balances: [String: Decimal]
    public let positions: [Position]
    public let cashUSD: Decimal
    public let cryptoValueUSD: Decimal
    public let netWorthUSD: Decimal

    public let realized: [RealizedGain]
    public let realizedShortTermUSD: Decimal
    public let realizedLongTermUSD: Decimal
    public let unrealizedUSD: Decimal

    /// Everything the user needs to resolve before the numbers can be trusted.
    public let transfersNeedingReview: [TransferMatcher.Candidate]
    public let unpairedTransfers: [LedgerEntry]
    public let uncoveredDisposals: [LedgerEntry]
    public let unpricedAcquisitions: [LedgerEntry]
    public let assetsMissingPrice: [String]

    /// True when lot quantities agree with raw balances for every asset.
    /// Any unmatched transfer breaks this, which is the point: silence would be
    /// worse than a visible discrepancy.
    public let reconciles: Bool

    public var hasOpenQuestions: Bool {
        !transfersNeedingReview.isEmpty || !unpairedTransfers.isEmpty
            || !uncoveredDisposals.isEmpty || !unpricedAcquisitions.isEmpty
            || !assetsMissingPrice.isEmpty
    }
}

/// Folds a raw entry stream into everything the UI renders.
public struct PortfolioEngine: Sendable {

    public var method: CostBasisMethod
    public var matcher: TransferMatcher

    public init(method: CostBasisMethod = .fifo, matcher: TransferMatcher = .init()) {
        self.method = method
        self.matcher = matcher
    }

    public func snapshot(
        entries: [LedgerEntry],
        spot: [String: Decimal],
        asOf: Date = Date()
    ) -> PortfolioSnapshot {

        let match = matcher.match(entries)

        var fees: [String: Decimal] = [:]
        for candidate in match.matched where candidate.differential > 0 {
            fees[candidate.inbound.id] = candidate.differential
        }

        let lots = LotEngine(method: method).replay(match.entries, transferFees: fees)

        var balances: [String: Decimal] = [:]
        for entry in match.entries {
            balances[entry.assetID, default: 0] += entry.qtyDelta
        }

        // Provenance is summed from the entries themselves, not from lots: lots
        // are pooled per asset by design, so they cannot say which account a
        // unit came from.
        var acctQty: [String: [String: Decimal]] = [:]
        for entry in match.entries {
            acctQty[entry.assetID, default: [:]][entry.accountID, default: 0] += entry.qtyDelta
        }

        var lotQty: [String: Decimal] = [:]
        var lotBasis: [String: Decimal] = [:]
        for lot in lots.openLots {
            lotQty[lot.assetID, default: 0] += lot.remainingQty
            lotBasis[lot.assetID, default: 0] += lot.remainingBasisUSD
        }

        var missingPrice: [String] = []
        var positions: [Position] = []
        for (assetID, qty) in lotQty where qty > 0 {
            let price = spot[assetID]
            if price == nil { missingPrice.append(assetID) }
            positions.append(
                Position(assetID: assetID,
                         qty: qty,
                         costBasisUSD: lotBasis[assetID] ?? 0,
                         spotUSD: price,
                         byAccount: Self.provenance(acctQty[assetID], total: qty))
            )
        }
        positions.sort {
            ($0.marketValueUSD ?? 0, $0.assetID) > ($1.marketValueUSD ?? 0, $1.assetID)
        }

        let cryptoValue = positions.reduce(Decimal(0)) { $0 + ($1.marketValueUSD ?? 0) }
        let unrealized = positions.reduce(Decimal(0)) { $0 + ($1.unrealizedUSD ?? 0) }
        let cash = balances["USD"] ?? 0

        let reconciles = balances
            .filter { !$0.key.isCashAsset && $0.value != 0 }
            .allSatisfy { lotQty[$0.key] == $0.value }

        return PortfolioSnapshot(
            asOf: asOf,
            method: method,
            balances: balances,
            positions: positions,
            cashUSD: cash,
            cryptoValueUSD: cryptoValue,
            // Net worth counts crypto plus cash you actually have. Cash can go
            // negative when a "buy" spends money that was never added as cash
            // (a common tracker case) — that's a phantom debt, not real net
            // worth, so it floors at zero here. Cost basis still records the
            // full price, so gains stay correct. Raw `cashUSD` is kept as-is.
            netWorthUSD: cryptoValue + Swift.max(0, cash),
            realized: lots.realized,
            realizedShortTermUSD: lots.realizedShortTermUSD,
            realizedLongTermUSD: lots.realizedLongTermUSD,
            unrealizedUSD: unrealized,
            transfersNeedingReview: match.needsReview,
            unpairedTransfers: match.unpaired,
            uncoveredDisposals: lots.uncoveredDisposals,
            unpricedAcquisitions: lots.unpricedAcquisitions,
            assetsMissingPrice: missingPrice.sorted(),
            reconciles: reconciles
        )
    }

    /// Per-account provenance for one asset, or empty when showing it would mislead.
    ///
    /// Disposals draw from pooled lots rather than from the account the units
    /// actually left, so after a sale the per-account parts can stop summing to
    /// the pooled total. Rather than render a breakdown that contradicts the row
    /// it sits under, say nothing.
    static func provenance(_ raw: [String: Decimal]?, total: Decimal) -> [AccountQty] {
        guard let raw else { return [] }
        let positive = raw.filter { $0.value > 0 }
        guard positive.count > 1 else { return [] }

        let sum = positive.values.reduce(0, +)
        guard sum > 0 else { return [] }
        let drift = sum > total ? sum - total : total - sum
        guard drift * 10_000 <= sum else { return [] }   // agree to within 0.01%

        return positive
            .map { AccountQty(accountID: $0.key, qty: $0.value) }
            .sorted { $0.qty == $1.qty ? $0.accountID < $1.accountID : $0.qty > $1.qty }
    }

}

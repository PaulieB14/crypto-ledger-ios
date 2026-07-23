import Foundation

public struct Position: Identifiable, Hashable, Sendable {
    public let assetID: String
    public let qty: Decimal
    public let costBasisUSD: Decimal
    public let spotUSD: Decimal?

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
                         spotUSD: price)
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
}

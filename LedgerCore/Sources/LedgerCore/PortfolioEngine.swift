import Foundation

/// One account's share of a position.
///
/// Lots themselves are per account (see `LotEngine`). This is the quantity
/// split the row shows — wallet ETH beside staked ETH, or which market a
/// debt sits in — so the total and the parts describe the same units.
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
    /// place. Empty when everything shares one account. Kept even when a later
    /// sale makes the parts disagree with the total — hiding them was dropping
    /// the only record of which wallet still holds what.
    public let byAccount: [AccountQty]
    /// True when these units are owed, not held. Market value is then subtracted
    /// from net worth. Quantity stays positive; the sign lives here.
    public var isLiability: Bool = false
    /// Lowest health factor among the loan legs that make up this debt, when
    /// the protocol reported one.
    public var healthFactor: Decimal? = nil

    public var id: String { isLiability ? "debt:\(assetID)" : assetID }
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
        var feeAccounts: [String: String] = [:]
        for candidate in match.matched where candidate.differential > 0 {
            fees[candidate.inbound.id] = candidate.differential
            // The fee left the source wallet. The destination has no lots yet.
            feeAccounts[candidate.inbound.id] = candidate.outbound.accountID
        }

        let lots = LotEngine(method: method).replay(
            match.entries, transferFees: fees, feeAccounts: feeAccounts)

        var balances: [String: Decimal] = [:]
        for entry in match.entries where !entry.kind.isLiability {
            balances[entry.assetID, default: 0] += entry.qtyDelta
        }

        // Provenance is the entry fold per account. Lots are already per
        // account, but a position row is still one asset, and this is what
        // tells wallet ETH from staked ETH underneath it.
        var acctQty: [String: [String: Decimal]] = [:]
        for entry in match.entries where !entry.kind.isLiability {
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
                         byAccount: Self.provenance(acctQty[assetID]))
            )
        }
        positions.sort {
            ($0.marketValueUSD ?? 0, $0.assetID) > ($1.marketValueUSD ?? 0, $1.assetID)
        }

        positions.append(contentsOf: Self.liabilities(in: match.entries, spot: spot, missing: &missingPrice))

        let assets = positions.filter { !$0.isLiability }
        let cryptoValue = assets.reduce(Decimal(0)) { $0 + ($1.marketValueUSD ?? 0) }
        let debtValue = positions.filter(\.isLiability).reduce(Decimal(0)) { $0 + ($1.marketValueUSD ?? 0) }
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
            // Net worth counts crypto plus cash you actually have, minus debt.
            // Cash can go negative when a "buy" spends money that was never
            // added as cash (a common tracker case) — that's a phantom debt,
            // not real net worth, so it floors at zero here. A crypto-backed
            // loan is a liability entry, not that negative cash, and it does
            // reduce net worth. Cost basis still records the full price, so
            // gains stay correct. Raw `cashUSD` is kept as-is.
            netWorthUSD: cryptoValue + Swift.max(0, cash) - debtValue,
            realized: lots.realized,
            realizedShortTermUSD: lots.realizedShortTermUSD,
            realizedLongTermUSD: lots.realizedLongTermUSD,
            unrealizedUSD: unrealized,
            transfersNeedingReview: match.needsReview,
            unpairedTransfers: match.unpaired,
            uncoveredDisposals: lots.uncoveredDisposals,
            unpricedAcquisitions: lots.unpricedAcquisitions,
            assetsMissingPrice: Array(Set(missingPrice)).sorted(),
            reconciles: reconciles
        )
    }

    /// Per-account quantities for one asset.
    ///
    /// One account has nothing to disambiguate, so the caption stays empty.
    /// More than one is always shown, even if a sale left the parts short of
    /// the row total — discarding them threw away which wallet still holds
    /// the remainder. `requireMultiple` is false for a debt row, where the
    /// single account name ("Aave Ethereum") is the point of the caption.
    static func provenance(_ raw: [String: Decimal]?, requireMultiple: Bool = true) -> [AccountQty] {
        guard let raw else { return [] }
        let positive = raw.filter { $0.value > 0 }
        if requireMultiple {
            guard positive.count > 1 else { return [] }
        } else if positive.isEmpty {
            return []
        }
        return positive
            .map { AccountQty(accountID: $0.key, qty: $0.value) }
            .sorted { $0.qty == $1.qty ? $0.accountID < $1.accountID : $0.qty > $1.qty }
    }

    /// Debt positions. Not lots: interest increasing the amount owed must not
    /// open a zero-cost acquisition the way a vault's balance growth does.
    private static func liabilities(
        in entries: [LedgerEntry],
        spot: [String: Decimal],
        missing: inout [String]
    ) -> [Position] {
        struct Bucket {
            var qty = Decimal(0)
            var basis = Decimal(0)
            var accounts: [String: Decimal] = [:]
            var health: Decimal?
        }
        var byAsset: [String: Bucket] = [:]
        for entry in entries where entry.kind.isLiability {
            let owed = entry.qtyDelta < 0 ? -entry.qtyDelta : entry.qtyDelta
            guard owed > 0 else { continue }
            var b = byAsset[entry.assetID] ?? Bucket()
            b.qty += owed
            if let price = entry.unitPriceUSD { b.basis += owed * price }
            b.accounts[entry.accountID, default: 0] += owed
            if let hf = entry.healthFactor {
                b.health = b.health.map { min($0, hf) } ?? hf
            }
            byAsset[entry.assetID] = b
        }
        var rows: [Position] = []
        for (assetID, b) in byAsset where b.qty > 0 {
            let price = spot[assetID]
            if price == nil { missing.append(assetID) }
            rows.append(Position(
                assetID: assetID,
                qty: b.qty,
                costBasisUSD: b.basis,
                spotUSD: price,
                byAccount: provenance(b.accounts, requireMultiple: false),
                isLiability: true,
                healthFactor: b.health))
        }
        rows.sort { ($0.marketValueUSD ?? 0, $0.assetID) > ($1.marketValueUSD ?? 0, $1.assetID) }
        return rows
    }

}

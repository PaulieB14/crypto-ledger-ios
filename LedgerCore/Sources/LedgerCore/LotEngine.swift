import Foundation

public enum CostBasisMethod: String, Codable, Sendable, CaseIterable {
    case fifo, lifo, hifo

    public var displayName: String {
        switch self {
        case .fifo: "First in, first out"
        case .lifo: "Last in, first out"
        case .hifo: "Highest cost first"
        }
    }
}

public struct Lot: Identifiable, Hashable, Sendable {
    public let id: String
    public let assetID: String
    /// Wallet (or protocol account) the lot was acquired in. A disposal only
    /// draws lots that share this id — basis does not cross accounts.
    public let accountID: String
    public let acquiredAt: Date
    public let originalQty: Decimal
    public var remainingQty: Decimal
    /// Cost per unit. Total basis is always derived, never stored, so partial
    /// disposals cannot drift away from the original.
    public let unitCostUSD: Decimal

    public var remainingBasisUSD: Decimal { remainingQty * unitCostUSD }
    public var isOpen: Bool { remainingQty > 0 }
}

public enum HoldingPeriod: String, Codable, Sendable {
    case short, long
}

public struct RealizedGain: Identifiable, Hashable, Sendable {
    public let id: String
    public let assetID: String
    public let acquiredAt: Date
    public let disposedAt: Date
    public let qty: Decimal
    public let proceedsUSD: Decimal
    public let basisUSD: Decimal
    public let holdingPeriod: HoldingPeriod
    /// Network fee burned in a wallet-to-wallet move: a real disposal at zero
    /// proceeds, flagged so it can be reviewed or excluded.
    public let isTransferFee: Bool

    public var gainUSD: Decimal { proceedsUSD - basisUSD }
}

public struct LotLedger: Sendable {
    public var openLots: [Lot]
    public var realized: [RealizedGain]
    /// Disposals with no lot to draw from. Almost always a missing import
    /// rather than a real event, so it is surfaced instead of assuming zero basis.
    public var uncoveredDisposals: [LedgerEntry]
    /// Acquisitions with no price attached.
    public var unpricedAcquisitions: [LedgerEntry]

    public var realizedShortTermUSD: Decimal {
        realized.filter { $0.holdingPeriod == .short }.reduce(0) { $0 + $1.gainUSD }
    }
    public var realizedLongTermUSD: Decimal {
        realized.filter { $0.holdingPeriod == .long }.reduce(0) { $0 + $1.gainUSD }
    }
    public var realizedTotalUSD: Decimal {
        realized.reduce(0) { $0 + $1.gainUSD }
    }
}

/// Replays entries in order and maintains open tax lots.
///
/// Lots are keyed by (account, asset). A sale, fee, or transfer-fee consumes
/// lots from that account only — Rev. Proc. 2024-28's per-wallet rule, and
/// the reason a HIFO sale in one wallet must not reach into another wallet's
/// expensive lot. FIFO / LIFO / HIFO still choose the order *within* the account.
///
/// Matched transfers do not relocate lots and do not realize, except the
/// network fee, which is written off from the source account (where the coins
/// were acquired). Moving specific lots onto the destination would change
/// which lots a later sale on the source wallet draws, and the known-answer
/// fixture is that case: the same coinbase BTC sale is long-term under FIFO
/// (+$8,400) and short-term under HIFO (+$3,000). Purchase prices stay
/// editable after the fact; this engine does not invent a transfer history.
public struct LotEngine: Sendable {

    public var method: CostBasisMethod
    public var calendar: Calendar

    public init(method: CostBasisMethod = .fifo, calendar: Calendar? = nil) {
        self.method = method
        if let calendar {
            self.calendar = calendar
        } else {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = TimeZone(identifier: "UTC")!
            self.calendar = gregorian
        }
    }

    /// - Parameters:
    ///   - entries: chronologically sorted, already run through `TransferMatcher`.
    ///   - transferFees: differential per matched transfer, keyed by the inbound entry id.
    public func replay(
        _ entries: [LedgerEntry],
        transferFees: [String: Decimal] = [:],
        feeAccounts: [String: String] = [:]
    ) -> LotLedger {

        var lots: [String: [Lot]] = [:]
        var realized: [RealizedGain] = []
        var uncovered: [LedgerEntry] = []
        var unpriced: [LedgerEntry] = []

        let ordered = entries.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }

        for entry in ordered {
            guard !entry.assetID.isCashAsset else { continue }

            if entry.kind.isAcquisition {
                guard let price = entry.unitPriceUSD else {
                    unpriced.append(entry)
                    continue
                }
                lots[Self.key(entry.accountID, entry.assetID), default: []].append(
                    Lot(id: entry.id,
                        assetID: entry.assetID,
                        accountID: entry.accountID,
                        acquiredAt: entry.timestamp,
                        originalQty: entry.qtyDelta,
                        remainingQty: entry.qtyDelta,
                        unitCostUSD: price)
                )

            } else if entry.kind.isDisposal {
                let qty = -entry.qtyDelta
                let proceeds = qty * (entry.unitPriceUSD ?? 0)
                consume(qty: qty, proceeds: proceeds, entry: entry,
                        accountID: entry.accountID, isTransferFee: false,
                        lots: &lots, realized: &realized, uncovered: &uncovered)

            } else if entry.kind == .transferIn, let fee = transferFees[entry.id], fee > 0 {
                // The quantity that never arrived. Written off where the coins
                // were acquired, not on the empty destination wallet.
                let source = feeAccounts[entry.id] ?? entry.accountID
                consume(qty: fee, proceeds: 0, entry: entry,
                        accountID: source, isTransferFee: true,
                        lots: &lots, realized: &realized, uncovered: &uncovered)

            } else if entry.kind == .fee, entry.qtyDelta < 0 {
                let qty = -entry.qtyDelta
                consume(qty: qty, proceeds: 0, entry: entry,
                        accountID: entry.accountID, isTransferFee: false,
                        lots: &lots, realized: &realized, uncovered: &uncovered)
            }
            // Liabilities are not lots and not disposals: the quantity owed is
            // folded into net worth separately. Matched transfers do not move
            // lots — see the type comment.
        }

        return LotLedger(
            openLots: lots.values.flatMap { $0 }.filter(\.isOpen)
                .sorted { ($0.assetID, $0.acquiredAt) < ($1.assetID, $1.acquiredAt) },
            realized: realized.sorted { $0.disposedAt < $1.disposedAt },
            uncoveredDisposals: uncovered,
            unpricedAcquisitions: unpriced
        )
    }

    private static func key(_ account: String, _ asset: String) -> String {
        account + "\u{1}" + asset
    }

    private func consume(
        qty: Decimal,
        proceeds: Decimal,
        entry: LedgerEntry,
        accountID: String,
        isTransferFee: Bool,
        lots: inout [String: [Lot]],
        realized: inout [RealizedGain],
        uncovered: inout [LedgerEntry]
    ) {
        guard qty > 0 else { return }
        let key = Self.key(accountID, entry.assetID)
        guard var available = lots[key], available.contains(where: \.isOpen) else {
            uncovered.append(entry)
            return
        }

        let order: [Int]
        let open = available.indices.filter { available[$0].isOpen }
        switch method {
        case .fifo: order = open.sorted { available[$0].acquiredAt < available[$1].acquiredAt }
        case .lifo: order = open.sorted { available[$0].acquiredAt > available[$1].acquiredAt }
        case .hifo: order = open.sorted { available[$0].unitCostUSD > available[$1].unitCostUSD }
        }

        var remaining = qty
        for index in order where remaining > 0 {
            let taken = min(available[index].remainingQty, remaining)
            guard taken > 0 else { continue }

            let basis = taken * available[index].unitCostUSD
            let share = proceeds * (taken / qty)

            realized.append(
                RealizedGain(
                    id: "\(entry.id)-\(available[index].id)",
                    assetID: entry.assetID,
                    acquiredAt: available[index].acquiredAt,
                    disposedAt: entry.timestamp,
                    qty: taken,
                    proceedsUSD: share,
                    basisUSD: basis,
                    holdingPeriod: holdingPeriod(
                        acquired: available[index].acquiredAt, disposed: entry.timestamp),
                    isTransferFee: isTransferFee
                )
            )

            available[index].remainingQty -= taken
            remaining -= taken
        }

        lots[key] = available
        if remaining > 0 { uncovered.append(entry) }
    }

    /// US rule: long-term requires holding *more than* one year, so an asset
    /// sold exactly on the anniversary is still short-term.
    func holdingPeriod(acquired: Date, disposed: Date) -> HoldingPeriod {
        guard let anniversary = calendar.date(byAdding: .year, value: 1, to: acquired) else {
            return .short
        }
        return disposed > anniversary ? .long : .short
    }
}

extension String {
    /// Cash is not lot-tracked.
    var isCashAsset: Bool { self == "USD" }
}

import Foundation

/// Pairs an outbound transfer with its inbound counterpart.
///
/// This is the single feature that separates a real tracker from a toy. Move
/// BTC from an exchange to a hardware wallet and a naive tracker books a sale
/// and a purchase: phantom realized gain, wrong cost basis, wrong tax return.
/// Matched pairs are non-taxable and consume no lots.
///
/// The quantity that goes missing across the pair is the network fee. It is a
/// genuine disposal with zero proceeds, so it is reported separately and the
/// lot engine writes it off at basis.
public struct TransferMatcher: Sendable {

    public struct Configuration: Sendable {
        /// How far apart the two legs may be. Exchange withdrawals to L1 can
        /// take hours; 6h is a reasonable default, tighten for L2-only users.
        public var window: TimeInterval = 6 * 3600
        /// Largest acceptable shortfall between legs, as a fraction of the
        /// outbound amount. Covers the network fee.
        public var quantityTolerance: Decimal = Decimal(string: "0.02")!
        /// Confidence at or above which a pair is linked without asking.
        public var autoMatchThreshold: Double = 0.80

        public init() {}
    }

    public struct Candidate: Sendable, Hashable {
        public let outbound: LedgerEntry
        public let inbound: LedgerEntry
        public let confidence: Double
        /// Quantity that did not arrive. Network fee.
        public let differential: Decimal
    }

    public struct Result: Sendable {
        /// Every entry, with `transferGroupID` populated on matched pairs.
        public var entries: [LedgerEntry]
        public var matched: [Candidate]
        /// Below threshold, or matched ambiguously. Show these to the user.
        public var needsReview: [Candidate]
        /// Transfers with no plausible counterpart at all.
        public var unpaired: [LedgerEntry]
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func match(_ entries: [LedgerEntry]) -> Result {
        let outbound = entries
            .filter { $0.kind == .transferOut && $0.transferGroupID == nil }
            .sorted { $0.timestamp < $1.timestamp }
        var availableInbound = entries
            .filter { $0.kind == .transferIn && $0.transferGroupID == nil }
            .sorted { $0.timestamp < $1.timestamp }

        var matched: [Candidate] = []
        var review: [Candidate] = []
        var unpaired: [LedgerEntry] = []
        var assignments: [String: String] = [:]   // entry.id -> transferGroupID

        for out in outbound {
            let scored = availableInbound
                .compactMap { score(out: out, in: $0) }
                .sorted { $0.confidence > $1.confidence }

            guard let best = scored.first else {
                unpaired.append(out)
                continue
            }

            if best.confidence >= configuration.autoMatchThreshold {
                let group = "xfer-\(out.id)"
                assignments[best.outbound.id] = group
                assignments[best.inbound.id] = group
                matched.append(best)
                availableInbound.removeAll { $0.id == best.inbound.id }
            } else {
                review.append(best)
            }
        }

        // Inbound legs nobody claimed. Usually a deposit from a third party,
        // or an account the user has not connected yet.
        let claimed = Set(matched.map(\.inbound.id))
        unpaired.append(contentsOf: availableInbound.filter { !claimed.contains($0.id) })

        let updated = entries.map { entry -> LedgerEntry in
            guard let group = assignments[entry.id] else { return entry }
            var copy = entry
            copy.transferGroupID = group
            return copy
        }

        return Result(entries: updated, matched: matched, needsReview: review, unpaired: unpaired)
    }

    /// Nil when the pair is disqualified outright.
    private func score(out: LedgerEntry, in inbound: LedgerEntry) -> Candidate? {
        guard out.assetID == inbound.assetID else { return nil }
        guard out.accountID != inbound.accountID else { return nil }

        let dt = inbound.timestamp.timeIntervalSince(out.timestamp)
        // Arrival cannot precede departure, allowing a little clock skew
        // between an exchange's timestamps and a chain's block times.
        guard dt >= -300, dt <= configuration.window else { return nil }

        let sent = -out.qtyDelta
        let received = inbound.qtyDelta
        guard sent > 0, received > 0, received <= sent else { return nil }

        let differential = sent - received
        let shortfall = differential / sent
        guard shortfall <= configuration.quantityTolerance else { return nil }

        let qtyScore = 1.0 - (shortfall / configuration.quantityTolerance).doubleValue
        let timeScore = 1.0 - (max(dt, 0) / configuration.window)

        return Candidate(
            outbound: out,
            inbound: inbound,
            confidence: 0.6 * qtyScore + 0.4 * timeScore,
            differential: differential
        )
    }
}

extension Decimal {
    var doubleValue: Double { (self as NSDecimalNumber).doubleValue }
}

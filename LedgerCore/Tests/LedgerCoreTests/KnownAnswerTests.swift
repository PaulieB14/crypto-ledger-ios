import Testing
import Foundation
@testable import LedgerCore

/// Expected values were computed by an independent reference implementation
/// before any of this Swift existed. Do not "fix" a failing assertion by
/// editing the expected number — the number is the specification.
///
/// The scenario deliberately exercises:
///   • a wallet-to-wallet transfer that must NOT realize a gain
///   • the 0.0005 BTC network fee inside that transfer, which is a real
///     disposal at zero proceeds
///   • a sale that is long-term under FIFO but short-term under HIFO
///   • a zero-cost airdrop later sold at a loss
///   • cash legs that must stay out of lot tracking
@Suite("Known-answer portfolio math")
struct KnownAnswerTests {

    let bundle: FixtureBundle

    init() throws {
        bundle = try FixtureBundle.load()
    }

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    // MARK: Balances

    @Test("Raw balances fold correctly")
    func balances() throws {
        let snap = PortfolioEngine(method: .fifo)
            .snapshot(entries: bundle.entries, spot: bundle.spot)

        #expect(snap.balances["BTC"] == dec("0.5995"))
        #expect(snap.balances["GRT"] == dec("500"))
        #expect(snap.balances["USD"] == dec("25145"))
    }

    // MARK: Transfer matching

    @Test("The wallet transfer matches and does not realize a gain")
    func transferMatches() throws {
        let result = TransferMatcher().match(bundle.entries)

        #expect(result.matched.count == 1)
        #expect(result.needsReview.isEmpty)
        #expect(result.unpaired.isEmpty)

        let pair = try #require(result.matched.first)
        #expect(pair.outbound.id == "e08")
        #expect(pair.inbound.id == "e09")
        #expect(pair.differential == dec("0.0005"))

        // Both legs carry the same group id after matching.
        let legs = result.entries.filter { $0.id == "e08" || $0.id == "e09" }
        #expect(legs.count == 2)
        #expect(legs[0].transferGroupID != nil)
        #expect(legs[0].transferGroupID == legs[1].transferGroupID)

        // A transfer is never a sale.
        #expect(!result.matched.contains { $0.outbound.kind.isDisposal })
    }

    // MARK: FIFO

    @Test("FIFO realized and unrealized")
    func fifo() throws {
        let snap = PortfolioEngine(method: .fifo)
            .snapshot(entries: bundle.entries, spot: bundle.spot)

        #expect(snap.realized.count == 3)

        // Network fee written off at basis, short-term.
        let fee = try #require(snap.realized.first { $0.isTransferFee })
        #expect(fee.qty == dec("0.0005"))
        #expect(fee.basisUSD == dec("21"))
        #expect(fee.gainUSD == dec("-21"))
        #expect(fee.holdingPeriod == .short)

        // 0.2 BTC drawn from the January lot -> held > 1 year.
        let btcSale = try #require(
            snap.realized.first { $0.assetID == "BTC" && !$0.isTransferFee })
        #expect(btcSale.proceedsUSD == dec("16800"))
        #expect(btcSale.basisUSD == dec("8400"))
        #expect(btcSale.gainUSD == dec("8400"))
        #expect(btcSale.holdingPeriod == .long)

        // Airdrop carries basis at value on receipt, sold below it.
        let grtSale = try #require(snap.realized.first { $0.assetID == "GRT" })
        #expect(grtSale.proceedsUSD == dec("55"))
        #expect(grtSale.basisUSD == dec("125"))
        #expect(grtSale.gainUSD == dec("-70"))
        #expect(grtSale.holdingPeriod == .long)

        #expect(snap.realizedShortTermUSD == dec("-21"))
        #expect(snap.realizedLongTermUSD == dec("8330"))

        #expect(snap.cryptoValueUSD == dec("56997.5"))
        #expect(snap.unrealizedUSD == dec("23593.5"))
        #expect(snap.netWorthUSD == dec("82142.5"))
    }

    // MARK: HIFO

    @Test("HIFO picks the expensive lot and flips the holding period")
    func hifo() throws {
        let snap = PortfolioEngine(method: .hifo)
            .snapshot(entries: bundle.entries, spot: bundle.spot)

        let btcSale = try #require(
            snap.realized.first { $0.assetID == "BTC" && !$0.isTransferFee })
        #expect(btcSale.basisUSD == dec("13800"))
        #expect(btcSale.gainUSD == dec("3000"))
        // Same sale, same day: long-term under FIFO, short-term under HIFO.
        #expect(btcSale.holdingPeriod == .short)

        #expect(snap.realizedShortTermUSD == dec("2965.5"))
        #expect(snap.realizedLongTermUSD == dec("-70"))
        #expect(snap.unrealizedUSD == dec("29007"))
    }

    // MARK: Invariants

    @Test("Net worth is identical across cost-basis methods", arguments: CostBasisMethod.allCases)
    func netWorthIsMethodInvariant(method: CostBasisMethod) throws {
        let snap = PortfolioEngine(method: method)
            .snapshot(entries: bundle.entries, spot: bundle.spot)
        // Method changes which lots you consume, never what you own.
        #expect(snap.netWorthUSD == dec("82142.5"))
        #expect(snap.balances["BTC"] == dec("0.5995"))
    }

    @Test("Realized plus unrealized is method-invariant in total",
          arguments: CostBasisMethod.allCases)
    func totalGainIsInvariant(method: CostBasisMethod) throws {
        let snap = PortfolioEngine(method: method)
            .snapshot(entries: bundle.entries, spot: bundle.spot)
        let total = snap.realizedShortTermUSD + snap.realizedLongTermUSD + snap.unrealizedUSD
        // Cost basis method shifts gain between realized and unrealized and
        // between short and long term. It cannot create or destroy gain.
        #expect(total == dec("31902.5"))
    }

    @Test("Lot quantities reconcile with raw balances", arguments: CostBasisMethod.allCases)
    func reconciles(method: CostBasisMethod) throws {
        let snap = PortfolioEngine(method: method)
            .snapshot(entries: bundle.entries, spot: bundle.spot)
        #expect(snap.reconciles)
        #expect(!snap.hasOpenQuestions)
    }

    @Test("Re-importing the same entries changes nothing")
    func idempotentImport() async throws {
        let source = FixtureSource(entries: bundle.entries)
        let aggregator = SourceAggregator(sources: [source, source, source])
        let entries = try await aggregator.loadAll()

        #expect(entries.count == bundle.entries.count)

        let snap = PortfolioEngine(method: .fifo).snapshot(entries: entries, spot: bundle.spot)
        #expect(snap.netWorthUSD == dec("82142.5"))
    }

    @Test("Decimal survives the JSON round trip")
    func decimalPrecision() throws {
        let entry = LedgerEntry(
            id: "p1", sourceID: "s", externalRef: "r",
            timestamp: Date(timeIntervalSince1970: 0),
            accountID: "a", assetID: "chain:0xabc",
            qtyDelta: Decimal(string: "0.123456789012345678")!,
            kind: .buy, unitPriceUSD: Decimal(string: "1234.56789")!)

        let data = try JSONEncoder().encode(entry)
        let restored = try JSONDecoder().decode(LedgerEntry.self, from: data)

        // A Double round trip loses this at the 17th digit.
        #expect(restored.qtyDelta == entry.qtyDelta)
        #expect(restored.unitPriceUSD == entry.unitPriceUSD)
    }
}

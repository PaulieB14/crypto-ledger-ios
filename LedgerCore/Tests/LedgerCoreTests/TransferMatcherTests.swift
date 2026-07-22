import Testing
import Foundation
@testable import LedgerCore

@Suite("Transfer matching edge cases")
struct TransferMatcherTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func entry(
        _ id: String, _ account: String, _ asset: String,
        _ qty: String, _ kind: EntryKind, minutesFromEpoch: Int
    ) -> LedgerEntry {
        LedgerEntry(
            id: id, sourceID: "test", externalRef: id,
            timestamp: Date(timeIntervalSince1970: TimeInterval(minutesFromEpoch * 60)),
            accountID: account, assetID: asset,
            qtyDelta: dec(qty), kind: kind, unitPriceUSD: dec("100"))
    }

    @Test("Arrival before departure is never a match")
    func rejectsTimeTravel() {
        let out = entry("o", "a", "ETH", "-1", .transferOut, minutesFromEpoch: 100)
        let inn = entry("i", "b", "ETH", "1", .transferIn, minutesFromEpoch: 10)
        let result = TransferMatcher().match([out, inn])

        #expect(result.matched.isEmpty)
        #expect(result.unpaired.count == 2)
    }

    @Test("Same account is never a match")
    func rejectsSelfTransfer() {
        let out = entry("o", "a", "ETH", "-1", .transferOut, minutesFromEpoch: 0)
        let inn = entry("i", "a", "ETH", "1", .transferIn, minutesFromEpoch: 5)
        #expect(TransferMatcher().match([out, inn]).matched.isEmpty)
    }

    @Test("Receiving more than was sent is never a match")
    func rejectsGrowth() {
        let out = entry("o", "a", "ETH", "-1", .transferOut, minutesFromEpoch: 0)
        let inn = entry("i", "b", "ETH", "1.5", .transferIn, minutesFromEpoch: 5)
        #expect(TransferMatcher().match([out, inn]).matched.isEmpty)
    }

    @Test("A shortfall beyond tolerance is not a fee, it is two events")
    func rejectsLargeShortfall() {
        let out = entry("o", "a", "ETH", "-1", .transferOut, minutesFromEpoch: 0)
        let inn = entry("i", "b", "ETH", "0.5", .transferIn, minutesFromEpoch: 5)
        #expect(TransferMatcher().match([out, inn]).matched.isEmpty)
    }

    @Test("Different assets never match")
    func rejectsAssetMismatch() {
        let out = entry("o", "a", "ETH", "-1", .transferOut, minutesFromEpoch: 0)
        let inn = entry("i", "b", "BTC", "1", .transferIn, minutesFromEpoch: 5)
        #expect(TransferMatcher().match([out, inn]).matched.isEmpty)
    }

    @Test("With two plausible arrivals, the closer one wins and the other stays free")
    func picksBestCandidate() throws {
        let out = entry("o", "a", "ETH", "-1", .transferOut, minutesFromEpoch: 0)
        let near = entry("near", "b", "ETH", "0.999", .transferIn, minutesFromEpoch: 3)
        let far = entry("far", "c", "ETH", "0.999", .transferIn, minutesFromEpoch: 200)

        let result = TransferMatcher().match([out, near, far])
        let pair = try #require(result.matched.first)

        #expect(pair.inbound.id == "near")
        #expect(result.unpaired.contains { $0.id == "far" })
    }

    @Test("One arrival cannot satisfy two departures")
    func inboundConsumedOnce() {
        let out1 = entry("o1", "a", "ETH", "-1", .transferOut, minutesFromEpoch: 0)
        let out2 = entry("o2", "a", "ETH", "-1", .transferOut, minutesFromEpoch: 1)
        let inn = entry("i", "b", "ETH", "0.999", .transferIn, minutesFromEpoch: 5)

        let result = TransferMatcher().match([out1, out2, inn])
        #expect(result.matched.count == 1)
        #expect(result.unpaired.count == 1)
    }

    @Test("An unmatched transfer breaks reconciliation instead of guessing")
    func unmatchedSurfacesAsOpenQuestion() {
        let buy = LedgerEntry(
            id: "b", sourceID: "t", externalRef: "b",
            timestamp: Date(timeIntervalSince1970: 0),
            accountID: "a", assetID: "ETH", qtyDelta: dec("2"),
            kind: .buy, unitPriceUSD: dec("1000"))
        let orphan = entry("o", "a", "ETH", "-1", .transferOut, minutesFromEpoch: 60)

        let snap = PortfolioEngine().snapshot(
            entries: [buy, orphan], spot: ["ETH": dec("2000")])

        // Balance says 1 ETH; lots still hold 2 because the departure was
        // never confirmed as either a transfer or a sale.
        #expect(snap.balances["ETH"] == dec("1"))
        #expect(!snap.reconciles)
        #expect(snap.hasOpenQuestions)
        #expect(snap.unpairedTransfers.count == 1)
        // Critically: no gain was invented.
        #expect(snap.realized.isEmpty)
    }
}

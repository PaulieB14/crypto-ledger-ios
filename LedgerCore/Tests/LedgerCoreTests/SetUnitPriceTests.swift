import XCTest
@testable import LedgerCore

final class SetUnitPriceTests: XCTestCase {
    private func entry(_ id: String, price: Decimal?) -> LedgerEntry {
        LedgerEntry(id: id, sourceID: "manual", externalRef: "livepeer-arbitrum-0xabc",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    accountID: "Livepeer Bonded", assetID: "LPT",
                    qtyDelta: Decimal(string: "2767.5")!, kind: .buy,
                    unitPriceUSD: price, groupID: "g1")
    }

    func testSettingPricePreservesIdentityAndClearsUnpriced() {
        let ledger = [entry("a", price: nil)]
        XCTAssertEqual(LotEngine().replay(ledger).unpricedAcquisitions.count, 1)

        let updated = ledger.settingUnitPrice(Decimal(string: "6.25")!, forEntry: "a")!
        let e = updated[0]
        XCTAssertEqual(e.id, "a")
        XCTAssertEqual(e.externalRef, "livepeer-arbitrum-0xabc")
        XCTAssertEqual(e.accountID, "Livepeer Bonded")
        XCTAssertEqual(e.qtyDelta, Decimal(string: "2767.5")!)
        XCTAssertEqual(e.groupID, "g1")
        XCTAssertEqual(e.unitPriceUSD, Decimal(string: "6.25")!)
        XCTAssertTrue(LotEngine().replay(updated).unpricedAcquisitions.isEmpty)
    }

    func testUnknownIDIsNoOp() {
        XCTAssertNil([entry("a", price: nil)].settingUnitPrice(1, forEntry: "zzz"))
    }
}

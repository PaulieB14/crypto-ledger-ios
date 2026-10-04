import Testing
import Foundation
@testable import LedgerCore

@Suite("Lending refresh is per wallet")
struct LendingReconcilerTests {

    private let walletA = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let walletB = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func entry(
        _ id: String, account: String, asset: String, qty: String,
        kind: EntryKind, price: String?, day: Int,
        health: String? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            id: id, sourceID: "test", externalRef: id,
            timestamp: Date(timeIntervalSince1970: Double(day) * 86_400),
            accountID: account, assetID: asset,
            qtyDelta: dec(qty), kind: kind,
            unitPriceUSD: price.map(dec),
            healthFactor: health.map(dec))
    }

    private func key(_ wallet: String) -> String {
        LendingAccountKey.accountID(protocolName: "Aave", chainLabel: "Ethereum", wallet: wallet)
    }

    private func update(
        _ wallet: String,
        collateralETH: String,
        debtUSDC: String,
        health: String? = nil,
        fullyRead: Bool = true
    ) -> LendingRefreshUpdate {
        LendingRefreshUpdate(
            accountID: key(wallet),
            legacyAccountID: LendingAccountKey.legacyAccountID(protocolName: "Aave", chainLabel: "Ethereum"),
            debt: ["USDC": dec(debtUSDC)],
            collateral: ["ETH": dec(collateralETH)],
            fullyRead: fullyRead,
            healthFactor: health.map(dec))
    }

    @Test("The account key is protocol, chain, and the full wallet address")
    func keyFormat() {
        let raw = "0xAbCd" + String(repeating: "E", count: 36)
        let id = LendingAccountKey.accountID(
            protocolName: "Aave", chainLabel: "Ethereum", wallet: "  \(raw)  ")
        #expect(id == "Aave Ethereum · " + raw.lowercased())
        #expect(LendingAccountKey.legacyAccountID(protocolName: "Aave", chainLabel: "Ethereum") == "Aave Ethereum")
        #expect(LendingAccountKey.accountID(protocolName: "Spark", chainLabel: "Ethereum", wallet: raw)
                != LendingAccountKey.accountID(protocolName: "Aave", chainLabel: "Ethereum", wallet: raw))
    }

    @Test("Two wallets on one market do not overwrite each other")
    func twoWalletsStaySeparate() {
        let entries = [
            entry("cA", account: key(walletA), asset: "ETH", qty: "10", kind: .airdrop, price: "2000", day: 1),
            entry("dA", account: key(walletA), asset: "USDC", qty: "-4000", kind: .liability, price: "1.05", day: 1, health: "1.8"),
            entry("cB", account: key(walletB), asset: "ETH", qty: "2", kind: .airdrop, price: "2000", day: 2),
            entry("dB", account: key(walletB), asset: "USDC", qty: "-500", kind: .liability, price: "1", day: 2, health: "3"),
        ]
        // B is refreshed last and reports a much smaller position. That used
        // to become the whole "Aave Ethereum" balance.
        let result = LendingReconciler.reconcile(entries: entries, updates: [
            update(walletA, collateralETH: "10.5", debtUSDC: "4100", health: "1.7"),
            update(walletB, collateralETH: "2", debtUSDC: "500", health: "3"),
        ])

        let byID = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.id, $0) })
        #expect(byID["cA"]?.accountID == key(walletA))
        #expect(byID["cA"]?.qtyDelta == dec("10.5"))
        #expect(byID["dA"]?.accountID == key(walletA))
        #expect(byID["dA"]?.qtyDelta == dec("-4100"))
        // Edited unit price survives the quantity change.
        #expect(byID["dA"]?.unitPriceUSD == dec("1.05"))
        #expect(byID["dA"]?.healthFactor == dec("1.7"))
        #expect(byID["cB"]?.qtyDelta == dec("2"))
        #expect(byID["cB"]?.accountID == key(walletB))
        #expect(byID["dB"]?.qtyDelta == dec("-500"))
        #expect(byID["dB"]?.accountID == key(walletB))
        #expect(byID["dB"]?.healthFactor == dec("3"))
        #expect(result.entries.count == 4)
    }

    @Test("A single wallet labeled only Aave Ethereum still refreshes, and the rewrite stores the wallet key")
    func legacyLabelStillRefreshes() {
        let entries = [
            entry("c", account: "Aave Ethereum", asset: "ETH", qty: "10", kind: .airdrop, price: "2000", day: 1),
            entry("d", account: "Aave Ethereum", asset: "USDC", qty: "-1000", kind: .liability, price: "1", day: 1, health: "2"),
        ]
        let result = LendingReconciler.reconcile(entries: entries, updates: [
            update(walletA, collateralETH: "11", debtUSDC: "1100", health: "1.9"),
        ])
        let byID = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.id, $0) })
        #expect(byID["c"]?.accountID == key(walletA))
        #expect(byID["c"]?.qtyDelta == dec("11"))
        #expect(byID["d"]?.accountID == key(walletA))
        #expect(byID["d"]?.qtyDelta == dec("-1100"))
        #expect(byID["d"]?.unitPriceUSD == dec("1"))
        #expect(byID["d"]?.healthFactor == dec("1.9"))
        #expect(result.entries.allSatisfy { $0.accountID != "Aave Ethereum" })

        // The stored key is what the next refresh matches, with no legacy row left.
        let again = LendingReconciler.reconcile(entries: result.entries, updates: [
            update(walletA, collateralETH: "12", debtUSDC: "1200", health: "1.9"),
        ])
        let next = Dictionary(uniqueKeysWithValues: again.entries.map { ($0.id, $0) })
        #expect(next["c"]?.qtyDelta == dec("12"))
        #expect(next["d"]?.qtyDelta == dec("-1200"))
        #expect(next["c"]?.accountID == key(walletA))
    }

    @Test("Two addresses already sharing the old label are not collapsed into the last response")
    func ambiguousLegacyIsLeftAlone() {
        let entries = [
            entry("cA", account: "Aave Ethereum", asset: "ETH", qty: "10", kind: .airdrop, price: "2000", day: 1),
            entry("dA", account: "Aave Ethereum", asset: "USDC", qty: "-4000", kind: .liability, price: "1", day: 1, health: "1.8"),
            entry("cB", account: "Aave Ethereum", asset: "ETH", qty: "3", kind: .airdrop, price: "2000", day: 2),
            entry("dB", account: "Aave Ethereum", asset: "USDC", qty: "-100", kind: .liability, price: "1", day: 2, health: "4"),
        ]
        let result = LendingReconciler.reconcile(entries: entries, updates: [
            update(walletA, collateralETH: "1", debtUSDC: "1", health: "1.1"),
            update(walletB, collateralETH: "9", debtUSDC: "9", health: "1.1"),
        ])
        let byID = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.id, $0) })
        #expect(byID["cA"]?.qtyDelta == dec("10"))
        #expect(byID["dA"]?.qtyDelta == dec("-4000"))
        #expect(byID["cB"]?.qtyDelta == dec("3"))
        #expect(byID["dB"]?.qtyDelta == dec("-100"))
        #expect(byID["cA"]?.accountID == "Aave Ethereum")
        #expect(byID["dB"]?.accountID == "Aave Ethereum")
        #expect(result.changed.isEmpty)
    }
}

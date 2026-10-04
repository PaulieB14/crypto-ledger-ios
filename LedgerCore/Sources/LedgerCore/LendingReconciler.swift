import Foundation

/// Account key for a lending position.
///
/// Import used to store `"Aave Ethereum"` for every wallet on that market.
/// Refresh then grouped every row with that label and let the last address
/// replace the combined collateral and debt. The key now carries the wallet
/// so two addresses are two accounts.
///
/// A row imported before that change has no wallet id. Refresh still matches
/// that exact legacy label, but only when a single wallet key claims it.
/// Two addresses must not share the group. A rewrite stores the new key, so
/// the next refresh is per address even if the old label was what matched.
public enum LendingAccountKey {

    /// Between the protocol/chain label and the wallet. Legacy labels have
    /// no separator, which is how they stay recognizable.
    public static let separator = " · "

    /// `Aave Ethereum · 0xabc…` — protocol, chain label, full address.
    public static func accountID(protocolName: String, chainLabel: String, wallet: String) -> String {
        let legacy = legacyAccountID(protocolName: protocolName, chainLabel: chainLabel)
        return legacy + separator + normalizedWallet(wallet)
    }

    /// The label written before the key included a wallet: `Aave Ethereum`.
    public static func legacyAccountID(protocolName: String, chainLabel: String) -> String {
        "\(protocolName) \(chainLabel)"
    }

    /// Lowercased, trimmed. Empty stays empty so a missing address cannot
    /// collide with a real one by both becoming some placeholder.
    public static func normalizedWallet(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// One protocol position, already read, ready to rewrite the ledger.
///
/// Amounts are keyed by asset symbol (uppercased). This is the pure half of
/// the refresh: no network, so two wallets can be tested without a node.
public struct LendingRefreshUpdate: Sendable {
    public var accountID: String
    public var legacyAccountID: String
    /// Symbol → amount owed. Not negative; the entry's quantity is.
    public var debt: [String: Decimal]
    /// Symbol → collateral amount.
    public var collateral: [String: Decimal]
    public var fullyRead: Bool
    public var healthFactor: Decimal?

    public init(
        accountID: String,
        legacyAccountID: String,
        debt: [String: Decimal],
        collateral: [String: Decimal],
        fullyRead: Bool,
        healthFactor: Decimal?
    ) {
        self.accountID = accountID
        self.legacyAccountID = legacyAccountID
        self.debt = debt
        self.collateral = collateral
        self.fullyRead = fullyRead
        self.healthFactor = healthFactor
    }
}

public struct LendingReconcileResult: Sendable {
    public var entries: [LedgerEntry]
    public var changed: [(account: String, from: Decimal, to: Decimal)]

    public init(
        entries: [LedgerEntry],
        changed: [(account: String, from: Decimal, to: Decimal)]
    ) {
        self.entries = entries
        self.changed = changed
    }
}

/// Rewrite loan entries to current collateral and debt, one wallet at a time.
public enum LendingReconciler {

    public static func reconcile(
        entries: [LedgerEntry],
        updates: [LendingRefreshUpdate]
    ) -> LendingReconcileResult {
        guard !updates.isEmpty else {
            return LendingReconcileResult(entries: entries, changed: [])
        }

        // A legacy label is safe to claim only when every update that names
        // it is the same wallet. Two addresses on "Aave Ethereum" must not
        // take turns overwriting that one group.
        var legacyOwners: [String: Set<String>] = [:]
        for update in updates {
            legacyOwners[update.legacyAccountID, default: []].insert(update.accountID)
        }

        var out = entries
        var changed: [(String, Decimal, Decimal)] = []
        for update in updates {
            let legacy = legacyOwners[update.legacyAccountID]?.count == 1
                ? update.legacyAccountID : nil
            out = apply(out, accountID: update.accountID, legacyAccountID: legacy,
                        fresh: update.debt, debt: true, dropMissing: update.fullyRead,
                        health: update.healthFactor, changed: &changed)
            out = apply(out, accountID: update.accountID, legacyAccountID: legacy,
                        fresh: update.collateral, debt: false, dropMissing: update.fullyRead,
                        health: nil, changed: &changed)
        }
        return LendingReconcileResult(
            entries: out.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) },
            changed: changed.map { (account: $0.0, from: $0.1, to: $0.2) })
    }

    /// Rewrite one wallet's existing legs. Never creates a row the user did
    /// not import. `dropMissing` is false on a partial read, so a reserve the
    /// node failed to return is left alone instead of booked as a repayment.
    ///
    /// Rows are matched on the wallet key, and on the legacy label when this
    /// wallet is the only claimant. Whatever matched is rewritten under the
    /// wallet key so the next refresh does not depend on the old label.
    private static func apply(
        _ entries: [LedgerEntry],
        accountID: String,
        legacyAccountID: String?,
        fresh: [String: Decimal],
        debt: Bool,
        dropMissing: Bool,
        health: Decimal?,
        changed: inout [(String, Decimal, Decimal)]
    ) -> [LedgerEntry] {
        let mine = entries.enumerated().filter {
            let id = $0.element.accountID
            let matches = id == accountID || (legacyAccountID != nil && id == legacyAccountID)
            return matches && ($0.element.kind == .liability) == debt
        }
        guard !mine.isEmpty else { return entries }
        let byAsset = Dictionary(grouping: mine, by: { $0.element.assetID })
        var remove = Set<Int>()
        var add: [LedgerEntry] = []

        for (asset, rows) in byAsset {
            let current = rows.reduce(Decimal(0)) { sum, row in
                let q = row.element.qtyDelta
                return sum + (q < 0 ? -q : q)
            }
            guard current > 0 else { continue }
            let next = fresh[asset]
            if next == nil {
                guard dropMissing else { continue }
                remove.formUnion(rows.map(\.offset))
                changed.append(("\(accountID) \(asset)", current, 0))
                continue
            }
            let target = next!
            let drift = target > current ? target - current : current - target
            let template = rows[0].element
            let healthMoved = debt && health != template.healthFactor
            guard drift * 10_000 > current || healthMoved else { continue }

            remove.formUnion(rows.map(\.offset))
            if target > 0 {
                let unit: Decimal?
                if debt {
                    // Keep the price the user set. Do not spread basis across
                    // the new, larger balance — that is the vault bug.
                    unit = template.unitPriceUSD
                } else {
                    let basis = rows.reduce(Decimal(0)) { sum, row in
                        sum + (row.element.unitPriceUSD.map { $0 * absQty(row.element.qtyDelta) } ?? 0)
                    }
                    let scaled = basis / target
                    unit = scaled > 0 ? scaled : template.unitPriceUSD
                }
                add.append(LedgerEntry(
                    id: template.id,
                    sourceID: template.sourceID,
                    externalRef: template.externalRef,
                    timestamp: template.timestamp,
                    accountID: accountID,
                    assetID: asset,
                    qtyDelta: debt ? -target : target,
                    kind: debt ? .liability : template.kind,
                    unitPriceUSD: unit,
                    groupID: template.groupID,
                    transferGroupID: template.transferGroupID,
                    healthFactor: debt ? (health ?? template.healthFactor) : nil))
            }
            changed.append(("\(accountID) \(asset)", current, target))
        }
        guard !remove.isEmpty else { return entries }
        return entries.enumerated().filter { !remove.contains($0.offset) }.map(\.element) + add
    }

    private static func absQty(_ q: Decimal) -> Decimal { q < 0 ? -q : q }
}

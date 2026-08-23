import Foundation
import LedgerCore

/// Keeps imported positions current — staked and held alike.
///
/// THE PROBLEM THIS SOLVES
/// A vault deposit imports as an ordinary balance entry, and ledger entries are
/// immutable — so the number freezes at the moment you added it while the vault
/// keeps earning. A week later the app quietly understates the position, and
/// re-importing to catch up does not fix it, it doubles it. That is the worst
/// shape a bug can have: silent, growing, and made worse by the obvious remedy.
///
/// WHAT IT DOES INSTEAD
/// On launch, re-ask StakeWise for the addresses you imported from and rewrite
/// each vault's entry to the current amount. Not append — rewrite, keyed on the
/// account label the import wrote ("StakeWise Data Nexus"), which is the same
/// key the portfolio uses to tell staked ETH from wallet ETH.
///
/// Total cost basis is carried across unchanged, so growth arrives at zero cost
/// (the conservative reading: rewards you did not pay for) and any basis you
/// edited by hand survives the refresh. No sale is ever synthesised — a vault
/// shrinking means you withdrew, and the ETH shows up in your wallet instead, so
/// booking a disposal here would invent a taxable event that did not happen.
///
/// It only ever updates positions already in the ledger. Deleting a staking
/// holding is a decision, and a background refresh must not overturn it by
/// silently putting the row back.
enum HoldingsRefresh {

    /// A full token scan crosses twelve explorers, so it is throttled. Staking is
    /// two GraphQL calls and runs every launch.
    private static let walletScanInterval: TimeInterval = 3600
    private static let lastScanKey = "argus.wallet.lastScan"


    /// Addresses whose staking positions are worth re-checking. Written at
    /// import; read on every launch.
    private static let addressesKey = "argus.staking.addresses"

    static func remember(address: String) {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard a.hasPrefix("0x"), a.count == 42 else { return }
        var all = UserDefaults.standard.stringArray(forKey: addressesKey) ?? []
        guard !all.contains(a) else { return }
        all.append(a)
        UserDefaults.standard.set(all, forKey: addressesKey)
    }

    static var watchedAddresses: [String] {
        UserDefaults.standard.stringArray(forKey: addressesKey) ?? []
    }

    static func forget(address: String) {
        let a = address.lowercased()
        UserDefaults.standard.set(watchedAddresses.filter { $0 != a }, forKey: addressesKey)
    }

    /// What a refresh changed, so the caller can decide whether to persist and
    /// whether to say anything to the user.
    struct Result: Sendable {
        var entries: [LedgerEntry]
        var changed: [(account: String, from: Decimal, to: Decimal)] = []
        var isEmpty: Bool { changed.isEmpty }
    }

    /// Rewrite staking entries in `entries` to match the vaults' current
    /// amounts. Pure: hands back a new array and a description of what moved.
    ///
    /// Returns the input untouched when no address is watched, when StakeWise
    /// cannot be reached, or when nothing has drifted — all three are "leave the
    /// ledger alone", and none of them are errors worth interrupting a launch for.
    static func reconcile(entries: [LedgerEntry]) async -> Result {
        let addresses = watchedAddresses
        guard !addresses.isEmpty else { return Result(entries: entries) }

        var live: [String: StakingPosition] = [:]   // accountID -> position
        for address in addresses {
            // nil means unreachable. Treating that as "you hold nothing" would
            // zero out real positions on a flaky connection, so it is skipped.
            guard let positions = await StakeWise.positions(address: address) else { continue }
            for p in positions { live["\(p.protocolName) \(p.vaultName)"] = p }
        }
        guard !live.isEmpty else { return Result(entries: entries) }

        var out = entries
        var changed: [(String, Decimal, Decimal)] = []

        for (account, position) in live {
            let mine = out.enumerated().filter {
                $0.element.accountID == account && $0.element.assetID == position.symbol.uppercased()
            }
            // Never create. An absent position was never imported, or was
            // deliberately deleted; both mean "not mine to add".
            guard !mine.isEmpty else { continue }

            let current = mine.reduce(Decimal(0)) { $0 + $1.element.qtyDelta }
            guard current > 0 else { continue }
            // Vault amounts move every block. Only rewrite on a difference big
            // enough to matter, or every launch rewrites the ledger for dust.
            let drift = position.amount > current ? position.amount - current : current - position.amount
            guard drift > Decimal(string: "0.0000001")! else { continue }

            // Carry total basis across, so growth lands at zero cost and a
            // hand-edited basis is not overwritten by a background task.
            let basis = mine.reduce(Decimal(0)) { sum, e in
                sum + (e.element.unitPriceUSD.map { $0 * e.element.qtyDelta } ?? 0)
            }
            let unitCost = position.amount > 0 ? basis / position.amount : 0
            let template = mine[0].element

            let indices = Set(mine.map(\.offset))
            out = out.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
            out.append(LedgerEntry(
                id: template.id,
                sourceID: template.sourceID,
                externalRef: "stakewise-\(position.chain)-\(position.vaultAddress)",
                timestamp: template.timestamp,
                accountID: account,
                assetID: position.symbol.uppercased(),
                qtyDelta: position.amount,
                kind: template.kind,
                unitPriceUSD: unitCost > 0 ? unitCost : template.unitPriceUSD))

            changed.append((account, current, position.amount))
        }

        return Result(entries: out.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) },
                      changed: changed.map { (account: $0.0, from: $0.1, to: $0.2) })
    }
}

extension HoldingsRefresh {

    /// Rewrite wallet holdings to their current on-chain balances.
    ///
    /// The same freeze that hits vaults hits rebasing tokens: stake.link's stLINK
    /// pays its yield by increasing your balance, so an imported number goes
    /// stale exactly like a StakeWise deposit does. Ordinary ERC-20s drift too,
    /// just for the ordinary reason that you moved some.
    ///
    /// Only entries the wallet import wrote are touched — matched on the
    /// "Wallet 0x…" account label. Anything you typed yourself, or edited (which
    /// rewrites the account to "Manual"), is left exactly as you left it. As with
    /// staking, positions are never created: a token you removed stays removed.
    ///
    /// Throttled, and skipped entirely when no chain could be reached, because
    /// "the network is down" and "you sold everything" produce identical empty
    /// scans and only one of them should rewrite a ledger.
    static func reconcileWallet(entries: [LedgerEntry], force: Bool = false) async -> Result {
        let addresses = watchedAddresses
        guard !addresses.isEmpty else { return Result(entries: entries) }

        if !force {
            let last = UserDefaults.standard.double(forKey: lastScanKey)
            guard Date().timeIntervalSince1970 - last > walletScanInterval else {
                return Result(entries: entries)
            }
        }

        var live: [String: [String: Decimal]] = [:]   // account -> symbol -> qty
        var contracts: [String: (chain: String, contract: String)] = [:]
        var reachedAny = false
        for address in addresses {
            let account = walletAccount(for: address)
            let scan = await WalletImporter.fetch(address: address, chains: Array(WalletChain.allCases))
            guard scan.reachedAnyChain else { continue }
            reachedAny = true

            // Only count what the import would have counted. A scan returns every
            // token ever airdropped at an address, including deliberate fakes —
            // and summing raw symbols would let a worthless contract calling
            // itself "ETH" quietly inflate a real ETH balance. Having a
            // confident price is the same bar the import applies, and a
            // counterfeit cannot clear it.
            let priced = await LlamaPrices.prices(for: scan.holdings)
            for h in scan.holdings {
                // Natives are the chain's own coin, not a contract, so nothing
                // can impersonate them and they need no price to be trusted —
                // which is just as well, since the explorer supplies no rate for
                // them and DefiLlama is only asked about contracts.
                guard h.contract == "native" || priced[h.id] != nil || h.priceUSD != nil
                else { continue }
                let symbol = h.symbol.uppercased()
                live[account, default: [:]][symbol, default: 0] += h.quantity
                if contracts[symbol] == nil, h.contract != "native" {
                    contracts[symbol] = (h.chain, h.contract)
                }
            }
        }
        guard reachedAny else { return Result(entries: entries) }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastScanKey)

        var out = entries
        var changed: [(String, Decimal, Decimal)] = []

        // Only assets already in the ledger under a wallet account are eligible.
        let walletEntries = entries.filter { $0.accountID.hasPrefix("Wallet 0x") }
        let eligible = Set(walletEntries.map { "\($0.accountID)\u{1}\($0.assetID)" })

        // Remember contracts for held symbols only. Registering all 177 tokens a
        // scan returns would grow without bound and reprice things nobody owns.
        for asset in Set(walletEntries.map(\.assetID)) {
            if let c = contracts[asset] {
                TokenRegistry.remember(symbol: asset, chain: c.chain, contract: c.contract)
            }
        }

        for key in eligible {
            let parts = key.split(separator: "\u{1}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (account, asset) = (parts[0], parts[1])
            // A symbol absent from a scan that DID reach its chains is a genuine
            // zero — the tokens are gone. Rewriting to zero would drop the row,
            // which is right, but it is also what a partial scan looks like, so
            // the safer read is to leave it and let the user remove it.
            guard let fresh = live[account]?[asset] else { continue }

            let mine = out.enumerated().filter {
                $0.element.accountID == account && $0.element.assetID == asset
            }
            guard !mine.isEmpty else { continue }
            let current = mine.reduce(Decimal(0)) { $0 + $1.element.qtyDelta }
            guard current > 0 else { continue }

            let drift = fresh > current ? fresh - current : current - fresh
            // Relative threshold: dust on a million-token balance is not dust on
            // a fractional one.
            guard drift * 10_000 > current else { continue }

            let basis = mine.reduce(Decimal(0)) { sum, e in
                sum + (e.element.unitPriceUSD.map { $0 * e.element.qtyDelta } ?? 0)
            }
            let unitCost = fresh > 0 ? basis / fresh : 0
            let template = mine[0].element
            let indices = Set(mine.map(\.offset))
            out = out.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
            out.append(LedgerEntry(
                id: template.id,
                sourceID: template.sourceID,
                externalRef: template.externalRef,
                timestamp: template.timestamp,
                accountID: account,
                assetID: asset,
                qtyDelta: fresh,
                kind: template.kind,
                unitPriceUSD: unitCost > 0 ? unitCost : template.unitPriceUSD))
            changed.append((("\(account) \(asset)"), current, fresh))
        }

        return Result(entries: out.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) },
                      changed: changed.map { (account: $0.0, from: $0.1, to: $0.2) })
    }

    /// The one place a wallet account label is built.
    ///
    /// Lowercased deliberately. The import sees the address as the user typed it
    /// and the refresh sees it as stored, so any case-sensitive derivation would
    /// produce two different labels for one wallet — "Wallet 0xAbCd…" on import,
    /// "Wallet 0xabcd…" on refresh — and the reconcile would silently match
    /// nothing at all. Checksummed addresses are the normal case, so this would
    /// be the normal outcome.
    static func walletAccount(for address: String) -> String {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard a.count >= 10 else { return "Wallet" }
        return "Wallet \(a.prefix(6))…\(a.suffix(4))"
    }
}

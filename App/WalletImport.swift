import Foundation

/// One token balance discovered on-chain for an address, on one chain.
struct WalletToken: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    let quantity: Decimal
    let chain: String
    /// Lowercased ERC-20 contract address, or "native" for the chain's own coin.
    let contract: String
    var id: String { "\(chain):\(contract)" }
}

/// A holding ready to import — the same symbol summed across every chain it was
/// found on (the app tracks holdings by symbol).
struct WalletHolding: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    let quantity: Decimal
    /// Lowercased ERC-20 contract address. THE identity of the token — symbols
    /// are attacker-controlled and routinely impersonated.
    let contract: String
    /// Which chain the contract lives on; the same address means different
    /// things on different chains.
    let chain: String
    var id: String { "\(chain):\(contract)" }
}

/// Result of a wallet scan: what was found, and whether any block explorer
/// actually answered. `holdings.isEmpty && !reachedAnyChain` is a network
/// failure, not an empty wallet, and the UI must say so.
struct WalletScan: Sendable {
    let holdings: [WalletHolding]
    let reachedAnyChain: Bool
}

/// Chains we scan, each via its public Blockscout instance. Keyless — nothing
/// secret ships in the app.
enum WalletChain: String, CaseIterable, Identifiable, Sendable {
    case ethereum, base, arbitrum, polygon, optimism, scroll, zksync, gnosis, celo, unichain, mode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ethereum: "Ethereum"
        case .base: "Base"
        case .arbitrum: "Arbitrum"
        case .polygon: "Polygon"
        case .optimism: "Optimism"
        case .scroll: "Scroll"
        case .zksync: "zkSync Era"
        case .gnosis: "Gnosis"
        case .celo: "Celo"
        case .unichain: "Unichain"
        case .mode: "Mode"
        }
    }

    var host: String {
        switch self {
        case .ethereum: "eth.blockscout.com"
        case .base: "base.blockscout.com"
        case .arbitrum: "arbitrum.blockscout.com"
        case .polygon: "polygon.blockscout.com"
        case .optimism: "optimism.blockscout.com"
        // Added 2026-08-21. Each verified live via /api/v2/stats before shipping —
        // a Blockscout host that 404s is indistinguishable from an empty wallet,
        // so an unchecked entry would silently report "no coins found".
        case .scroll: "scroll.blockscout.com"
        case .zksync: "zksync.blockscout.com"
        case .gnosis: "gnosis.blockscout.com"
        case .celo: "celo.blockscout.com"
        case .unichain: "unichain.blockscout.com"
        case .mode: "explorer.mode.network"
        }
    }

    /// Native coin symbol (what `coin_balance` is denominated in).
    var nativeSymbol: String {
        switch self {
        case .polygon: "POL"
        case .gnosis: "XDAI"
        case .celo: "CELO"
        default: "ETH"   // scroll, zksync, unichain, mode are all ETH-denominated
        }
    }
}

/// A basic 0x… 40-hex-char address check. Not a checksum — just enough to avoid
/// firing requests at obvious typos.
func isValidEVMAddress(_ s: String) -> Bool {
    let a = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard a.count == 42, a.hasPrefix("0x") else { return false }
    return a.dropFirst(2).allSatisfy { $0.isHexDigit }
}

/// Reads balances from public Blockscout APIs. No key, no account.
enum WalletImporter {

    /// Fetch native + ERC-20 balances for `address` across `chains`, summed by
    /// symbol. Chains are scanned concurrently; a chain that fails is skipped.
    ///
    /// Returns reachability alongside the holdings. Without it the caller cannot
    /// tell "this address holds nothing" from "every block explorer was
    /// unreachable" — and it was telling users to double-check a perfectly valid
    /// address whenever the network was blocked.
    static func fetch(address: String, chains: [WalletChain]) async -> WalletScan {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [WalletToken] = []
        var reachedAnyChain = false
        await withTaskGroup(of: [WalletToken]?.self) { group in
            for chain in chains {
                group.addTask { await tokens(address: addr, chain: chain) }
            }
            for await list in group {
                guard let list else { continue }   // nil == chain unreachable
                reachedAnyChain = true
                found.append(contentsOf: list)
            }
        }
        // SUM BY CONTRACT, NEVER BY SYMBOL.
        //
        // Symbols are attacker-controlled. A single mainnet address commonly holds
        // several airdropped tokens all calling themselves "USDC" — Vitalik's
        // wallet returns 6,687 ERC-20s, topped by junk minted at 10^59 units.
        // Summing by symbol merged those into the real holding, and pricing by
        // symbol then valued the counterfeit at the genuine coin's price. That is
        // how a wallet import produced a portfolio worth more than the world
        // economy. The contract address is the only identity that cannot be
        // spoofed, and the same address means different things per chain, so the
        // key is (chain, contract).
        var byContract: [String: WalletHolding] = [:]
        for t in found {
            let key = "\(t.chain):\(t.contract)"
            if let existing = byContract[key] {
                byContract[key] = WalletHolding(symbol: existing.symbol, name: existing.name,
                                                quantity: existing.quantity + t.quantity,
                                                contract: existing.contract, chain: existing.chain)
            } else {
                byContract[key] = WalletHolding(symbol: t.symbol, name: t.name, quantity: t.quantity,
                                                contract: t.contract, chain: t.chain)
            }
        }
        return WalletScan(holdings: byContract.values.sorted { $0.symbol < $1.symbol },
                          reachedAnyChain: reachedAnyChain)
    }

    /// nil means the chain could not be reached at all (DNS/TLS/timeout/HTTP
    /// error on BOTH probes). An empty array means it answered and the address
    /// holds nothing there — a genuinely different fact.
    private static func tokens(address: String, chain: WalletChain) async -> [WalletToken]? {
        var result: [WalletToken] = []
        var answered = false

        // ERC-20 balances.
        if let arr = await getArray("https://\(chain.host)/api/v2/addresses/\(address)/token-balances") {
            answered = true
            for item in arr {
                guard let token = item["token"] as? [String: Any],
                      let type = (token["type"] as? String)?.uppercased(),
                      type.replacingOccurrences(of: "-", with: "") == "ERC20",
                      let sym = (token["symbol"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !sym.isEmpty,
                      let rawStr = item["value"] as? String,
                      let raw = Decimal(string: rawStr), raw > 0 else { continue }
                let decimals = Int((token["decimals"] as? String) ?? "") ?? 18
                let qty = raw / pow10(decimals)
                guard qty > 0 else { continue }
                // No contract address means we cannot identify or price the token
                // safely, so drop it rather than fall back to trusting the symbol.
                guard let addr = (token["address"] as? String ?? token["address_hash"] as? String)?
                        .trimmingCharacters(in: .whitespaces).lowercased(), !addr.isEmpty else { continue }
                let name = (token["name"] as? String) ?? sym
                result.append(WalletToken(symbol: sym.uppercased(), name: name,
                                          quantity: qty, chain: chain.rawValue, contract: addr))
            }
        }

        // Native coin balance.
        if let obj = await getObject("https://\(chain.host)/api/v2/addresses/\(address)") {
            answered = true
            if let weiStr = obj["coin_balance"] as? String,
               let wei = Decimal(string: weiStr), wei > 0 {
                let qty = wei / pow10(18)
                if qty > 0 {
                    result.append(WalletToken(symbol: chain.nativeSymbol, name: chain.nativeSymbol,
                                              quantity: qty, chain: chain.rawValue, contract: "native"))
                }
            }
        }
        return answered ? result : nil
    }

    private static func getArray(_ urlStr: String) async -> [[String: Any]]? {
        guard let data = await get(urlStr) else { return nil }
        // Blockscout returns a bare array here, but tolerate a paginated
        // { "items": [...] } shape too.
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return arr }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = obj["items"] as? [[String: Any]] { return items }
        return nil
    }

    private static func getObject(_ urlStr: String) async -> [String: Any]? {
        guard let data = await get(urlStr) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func get(_ urlStr: String) async -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue("argus", forHTTPHeaderField: "user-agent")
        return try? await URLSession.shared.data(for: req).0
    }

    private static func pow10(_ n: Int) -> Decimal {
        var r = Decimal(1)
        for _ in 0..<max(0, n) { r *= 10 }
        return r
    }
}

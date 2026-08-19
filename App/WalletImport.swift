import Foundation

/// One token balance discovered on-chain for an address, on one chain.
struct WalletToken: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    let quantity: Decimal
    let chain: String
    var id: String { "\(chain)-\(symbol)" }
}

/// A holding ready to import — the same symbol summed across every chain it was
/// found on (the app tracks holdings by symbol).
struct WalletHolding: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    let quantity: Decimal
    var id: String { symbol }
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
    case ethereum, base, arbitrum, polygon, optimism

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ethereum: "Ethereum"
        case .base: "Base"
        case .arbitrum: "Arbitrum"
        case .polygon: "Polygon"
        case .optimism: "Optimism"
        }
    }

    var host: String {
        switch self {
        case .ethereum: "eth.blockscout.com"
        case .base: "base.blockscout.com"
        case .arbitrum: "arbitrum.blockscout.com"
        case .polygon: "polygon.blockscout.com"
        case .optimism: "optimism.blockscout.com"
        }
    }

    /// Native coin symbol (what `coin_balance` is denominated in).
    var nativeSymbol: String {
        switch self {
        case .polygon: "POL"
        default: "ETH"
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
        // Sum by symbol across chains.
        var bySymbol: [String: WalletHolding] = [:]
        for t in found {
            if let existing = bySymbol[t.symbol] {
                bySymbol[t.symbol] = WalletHolding(symbol: t.symbol, name: existing.name,
                                                   quantity: existing.quantity + t.quantity)
            } else {
                bySymbol[t.symbol] = WalletHolding(symbol: t.symbol, name: t.name, quantity: t.quantity)
            }
        }
        return WalletScan(holdings: bySymbol.values.sorted { $0.symbol < $1.symbol },
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
                let name = (token["name"] as? String) ?? sym
                result.append(WalletToken(symbol: sym.uppercased(), name: name,
                                          quantity: qty, chain: chain.rawValue))
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
                                              quantity: qty, chain: chain.rawValue))
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

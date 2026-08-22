import Foundation

/// Contract-addressed pricing, used ahead of the explorer's own rate.
///
/// WHY THIS EXISTS
/// The two sources that came before it miss the same class of token, in
/// opposite ways.
///
/// Blockscout's `exchange_rate` is per-explorer and can be drawn from a thin or
/// stale pool. It valued stake.link's stLINK at $8.26 while LINK — which stLINK
/// is a redeemable claim on — traded at $11.75, understating a real position by
/// 30%. Believable-looking and badly wrong is the worst failure mode a balance
/// screen has.
///
/// CoinGecko here is keyed by symbol across the top 1000 by market cap, so
/// anything smaller is simply absent. osETH, the token StakeWise mints against a
/// vault deposit, is rank 7193.
///
/// DefiLlama is addressed by (chain, contract) rather than by symbol, so a
/// counterfeit cannot impersonate a real coin by naming itself after it, and it
/// returns a per-quote confidence, so a thin market can be declined instead of
/// believed. Keyless, like every other source in this app.
enum LlamaPrices {

    /// DefiLlama's chain slugs. Each verified against a known token on that
    /// chain — they are not all the names Argus uses (Gnosis is `xdai`, zkSync
    /// Era is `era`).
    ///
    /// Plasma is deliberately absent: it is native-only here, with no token
    /// scan, so there is no contract to price.
    private static let slug: [String: String] = [
        "ethereum": "ethereum", "base": "base", "arbitrum": "arbitrum",
        "polygon": "polygon", "optimism": "optimism", "scroll": "scroll",
        "zksync": "era", "gnosis": "xdai", "celo": "celo",
        "unichain": "unichain", "mode": "mode",
    ]

    /// Below this the quote is thin enough that it is not clearly better than
    /// what the explorer already said. Declining leaves the existing fallback in
    /// place rather than swapping one unreliable number for another.
    private static let minConfidence = 0.9

    /// 150 keys in one URL is proven to work; 100 leaves headroom.
    private static let batchSize = 100

    /// Live USD prices keyed by `WalletHolding.id` (`"chain:contract"`).
    ///
    /// Absent keys mean "no confident quote", never "free". Callers must fall
    /// through to their existing sources rather than treat a miss as zero.
    static func prices(for holdings: [WalletHolding]) async -> [String: Decimal] {
        // Natives are priced by symbol elsewhere and have no contract to look up.
        let wanted = holdings.filter { $0.contract != "native" && slug[$0.chain] != nil }
        guard !wanted.isEmpty else { return [:] }

        // The API echoes each key back exactly as sent, so send one canonical
        // form and look up that same form. Contracts arrive lowercased from the
        // explorer already; lowercasing again makes that a local guarantee
        // rather than an assumption about upstream.
        var keyToHolding: [String: String] = [:]
        for h in wanted {
            keyToHolding["\(slug[h.chain]!):\(h.contract.lowercased())"] = h.id
        }

        let keys = Array(keyToHolding.keys)
        let batches = stride(from: 0, to: keys.count, by: batchSize).map {
            Array(keys[$0 ..< min($0 + batchSize, keys.count)])
        }

        var out: [String: Decimal] = [:]
        await withTaskGroup(of: [String: Decimal].self) { group in
            for batch in batches {
                group.addTask { await fetch(batch, keyToHolding: keyToHolding) }
            }
            for await part in group { out.merge(part) { a, _ in a } }
        }
        return out
    }

    private static func fetch(_ batch: [String],
                              keyToHolding: [String: String]) async -> [String: Decimal] {
        // Contract addresses are hex and slugs are alphanumeric, so the joined
        // path needs no escaping — but build it through URLComponents anyway so
        // a future slug with an odd character cannot silently produce a bad URL.
        var comps = URLComponents(string: "https://coins.llama.fi/prices/current/")
        comps?.path += batch.joined(separator: ",")
        guard let url = comps?.url else { return [:] }

        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("application/json", forHTTPHeaderField: "accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return [:] }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coins = root["coins"] as? [String: Any] else { return [:] }

        var out: [String: Decimal] = [:]
        for (key, raw) in coins {
            guard let entry = raw as? [String: Any],
                  let holdingID = keyToHolding[key],
                  let price = entry["price"] as? Double, price > 0 else { continue }
            // An unknown contract is omitted from the response rather than
            // returned at zero, so a missing confidence means malformed, not
            // worthless. Treat it as no answer.
            guard let confidence = entry["confidence"] as? Double,
                  confidence >= minConfidence else { continue }
            guard let dec = Decimal(string: String(price)) else { continue }
            out[holdingID] = dec
        }
        return out
    }
}

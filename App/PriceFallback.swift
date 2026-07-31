import Foundation

/// Where the prices on screen came from.
///
/// A fallback that silently swaps data sources is worse than one that says so,
/// because the numbers change and nothing explains why.
enum PriceSource: String, Sendable, Codable {
    case coinGecko
    case coinpaprika
    case cache

    var displayName: String {
        switch self {
        case .coinGecko:    "CoinGecko"
        case .coinpaprika:  "Coinpaprika"
        case .cache:        "your last update"
        }
    }
}

/// Keyless, signup-free price source used when CoinGecko is unavailable.
///
/// CoinGecko's anonymous quota is per-IP, so it fails exactly when many clients
/// share one address — an office, a carrier NAT, or Apple's review network.
/// Coinpaprika returns ~2,000 coins with USD prices in a single request and
/// needs no key at all, so the app can always show a live market rather than an
/// error. It carries no logo URLs; the lettered badge covers that.
enum Coinpaprika {
    static func topMarkets(limit: Int = 1000) async throws -> [CoinMarket] {
        guard let url = URL(string: "https://api.coinpaprika.com/v1/tickers?quotes=USD") else {
            throw CoinGeckoError.malformed
        }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue("crypto-ledger", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CoinGeckoError.unreachable(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code) else {
            throw code == 429 ? CoinGeckoError.rateLimited : CoinGeckoError.http(code)
        }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw CoinGeckoError.malformed
        }

        let coins: [CoinMarket] = raw.compactMap { d in
            guard let id = d["id"] as? String,
                  let sym = d["symbol"] as? String,
                  let name = d["name"] as? String,
                  let quotes = d["quotes"] as? [String: Any],
                  let usd = quotes["USD"] as? [String: Any],
                  let p = usd["price"] as? NSNumber
            else { return nil }
            let rank = d["rank"] as? Int
            // Coinpaprika ranks unlisted coins 0; treat that as "no rank" so they
            // sort to the back instead of ahead of Bitcoin.
            return CoinMarket(id: id, symbol: sym.uppercased(), name: name,
                              priceUSD: Decimal(string: p.stringValue) ?? 0,
                              rank: (rank ?? 0) > 0 ? rank : nil,
                              imageURL: nil)
        }
        return Array(coins.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }.prefix(limit))
    }
}

/// Last known coin list, persisted so a launch that can't reach any provider
/// still opens on real prices instead of an empty screen. Stale prices with a
/// banner saying they're stale beat no prices at all.
enum CoinCache {
    private struct Payload: Codable {
        let coins: [CoinMarket]
        let savedAt: Date
        let source: PriceSource
    }

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("CryptoLedger", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("coins.json")
    }

    static func save(_ coins: [CoinMarket], source: PriceSource) {
        guard !coins.isEmpty, let url = fileURL else { return }
        let payload = Payload(coins: coins, savedAt: Date(), source: source)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> (coins: [CoinMarket], savedAt: Date)? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.coins.isEmpty
        else { return nil }
        return (payload.coins, payload.savedAt)
    }
}

import Foundation
import Observation
import SwiftUI

/// One coin from CoinGecko's market list — symbol, name, live USD price.
struct CoinMarket: Identifiable, Hashable, Sendable {
    let id: String        // CoinGecko id, e.g. "bitcoin"
    let symbol: String    // "BTC"
    let name: String      // "Bitcoin"
    let priceUSD: Decimal
    let rank: Int?
    let imageURL: URL?    // CDN logo (badge-sized)
}

/// One point on a coin's price history, for the sparkline/detail chart.
struct PricePoint: Identifiable, Hashable, Sendable {
    let date: Date
    let priceUSD: Double
    var id: Date { date }
}

/// Thin CoinGecko client. Public, free, no key — the top markets by market cap
/// give us live prices and a searchable universe of essentially every coin a
/// user actually holds.
enum CoinGecko {
    /// Fetch the top `pages * perPage` coins by market cap (default top 1000 —
    /// four pages fetched concurrently). Wider coverage means far fewer real
    /// holdings fall into the "no live price" gap.
    static func topMarkets(pages: Int = 4, perPage: Int = 250) async -> [CoinMarket] {
        await withTaskGroup(of: [CoinMarket].self) { group in
            for page in 1...max(1, pages) {
                group.addTask { await marketsPage(page: page, perPage: perPage) }
            }
            var all: [CoinMarket] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
        }
    }

    private static func marketsPage(page: Int, perPage: Int) async -> [CoinMarket] {
        var comps = URLComponents(string: "https://api.coingecko.com/api/v3/coins/markets")!
        comps.queryItems = [
            .init(name: "vs_currency", value: "usd"),
            .init(name: "order", value: "market_cap_desc"),
            .init(name: "per_page", value: String(perPage)),
            .init(name: "page", value: String(page)),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("crypto-ledger", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let raw = (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            return raw.compactMap { d in
                guard let id = d["id"] as? String,
                      let sym = d["symbol"] as? String,
                      let name = d["name"] as? String else { return nil }
                let price: Decimal
                if let n = d["current_price"] as? NSNumber {
                    price = Decimal(string: n.stringValue) ?? 0
                } else { price = 0 }
                // Prefer the smaller CDN variant for a crisp badge without the weight.
                let img = (d["image"] as? String)?
                    .replacingOccurrences(of: "/large/", with: "/small/")
                return CoinMarket(id: id, symbol: sym.uppercased(), name: name,
                                  priceUSD: price, rank: d["market_cap_rank"] as? Int,
                                  imageURL: img.flatMap(URL.init(string:)))
            }
        } catch {
            return []
        }
    }

    /// Daily USD price history for one coin (by CoinGecko id), for the detail
    /// chart. Returns [] on any failure so the UI can degrade gracefully.
    static func priceHistory(coinID: String, days: Int = 30) async -> [PricePoint] {
        var comps = URLComponents(string: "https://api.coingecko.com/api/v3/coins/\(coinID)/market_chart")!
        comps.queryItems = [
            .init(name: "vs_currency", value: "usd"),
            .init(name: "days", value: String(days)),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("crypto-ledger", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let prices = obj?["prices"] as? [[Any]] ?? []
            return prices.compactMap { pair in
                guard pair.count == 2,
                      let ms = (pair[0] as? NSNumber)?.doubleValue,
                      let price = (pair[1] as? NSNumber)?.doubleValue else { return nil }
                return PricePoint(date: Date(timeIntervalSince1970: ms / 1000), priceUSD: price)
            }
        } catch {
            return []
        }
    }
}

/// Loads and holds the coin universe + live prices. One fetch, cached for the
/// session; degrades to an empty list (offline) without breaking the app.
@Observable
@MainActor
final class CoinCatalog {
    private(set) var coins: [CoinMarket] = []
    private(set) var isLoading = false
    private(set) var loadedOnce = false

    func load() async {
        guard !loadedOnce else { return }
        isLoading = true
        coins = await CoinGecko.topMarkets()
        isLoading = false
        loadedOnce = !coins.isEmpty   // allow a retry if the first fetch failed
    }

    /// Force a fresh price fetch — used when the app returns to the foreground
    /// so holdings and alerts are checked against current quotes.
    func reload() async {
        let fresh = await CoinGecko.topMarkets()
        if !fresh.isEmpty {
            coins = fresh
            loadedOnce = true
        }
    }

    func filtered(_ query: String) -> [CoinMarket] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return coins }
        return coins.filter {
            $0.symbol.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    /// symbol → price, highest-market-cap coin wins per symbol.
    var spotMap: [String: Decimal] {
        var m: [String: Decimal] = [:]
        for c in coins where m[c.symbol] == nil { m[c.symbol] = c.priceUSD }
        return m
    }

    func price(for symbol: String) -> Decimal? {
        let s = symbol.uppercased()
        return coins.first { $0.symbol == s }?.priceUSD
    }

    func imageURL(for symbol: String) -> URL? {
        let s = symbol.uppercased()
        return coins.first { $0.symbol == s }?.imageURL
    }

    /// CoinGecko id for a symbol (e.g. "BTC" -> "bitcoin"), needed to fetch that
    /// coin's price history.
    func coinID(for symbol: String) -> String? {
        let s = symbol.uppercased()
        return coins.first { $0.symbol == s }?.id
    }

    /// symbol -> CoinGecko id, for reconstructing net-worth history.
    func coinIDMap() -> [String: String] {
        var m: [String: String] = [:]
        for c in coins where m[c.symbol] == nil { m[c.symbol] = c.id }
        return m
    }

    /// Full coin name for a symbol (falls back to the symbol itself).
    func name(for symbol: String) -> String {
        let s = symbol.uppercased()
        return coins.first { $0.symbol == s }?.name ?? symbol
    }
}

/// A searchable list of every coin, with live prices. Powers "add any crypto".
struct CoinPickerView: View {
    @Environment(\.dismiss) private var dismiss
    var catalog: CoinCatalog
    var onPick: (CoinMarket) -> Void

    @State private var query = ""

    var body: some View {
        List(catalog.filtered(query)) { coin in
            Button {
                onPick(coin)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    AssetBadge(symbol: coin.symbol, imageURL: coin.imageURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coin.symbol).fontWeight(.semibold)
                        Text(coin.name).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(coin.priceUSD, format: .currency(code: "USD"))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .searchable(text: $query, prompt: "Search \(catalog.coins.count) coins")
        .overlay {
            if catalog.coins.isEmpty {
                if catalog.isLoading {
                    ProgressView("Loading coins…")
                } else {
                    ContentUnavailableView("Couldn't reach CoinGecko",
                                           systemImage: "wifi.slash",
                                           description: Text("Check your connection and try again — you can still type a symbol by hand."))
                }
            }
        }
        .navigationTitle("Choose asset")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await catalog.load() }
    }
}

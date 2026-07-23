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

/// Thin CoinGecko client. Public, free, no key — the top markets by market cap
/// give us live prices and a searchable universe of essentially every coin a
/// user actually holds.
enum CoinGecko {
    static func topMarkets(perPage: Int = 250) async -> [CoinMarket] {
        var comps = URLComponents(string: "https://api.coingecko.com/api/v3/coins/markets")!
        comps.queryItems = [
            .init(name: "vs_currency", value: "usd"),
            .init(name: "order", value: "market_cap_desc"),
            .init(name: "per_page", value: String(perPage)),
            .init(name: "page", value: "1"),
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

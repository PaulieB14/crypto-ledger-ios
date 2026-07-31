import Foundation
import Observation
import SwiftUI

/// One coin from a market list — symbol, name, live USD price.
struct CoinMarket: Identifiable, Hashable, Sendable, Codable {
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

/// Why a price fetch failed. Surfaced in the UI rather than swallowed: an
/// empty coin list and a failed request look identical on screen and are very
/// different problems — the second one is the reviewer seeing a broken app.
enum CoinGeckoError: LocalizedError, Sendable, Equatable {
    case rateLimited
    case http(Int)
    case unreachable(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .rateLimited:      "CoinGecko is rate-limiting requests right now."
        case .http(let code):   "CoinGecko returned HTTP \(code)."
        case .unreachable(let why): why
        case .malformed:        "CoinGecko sent a response Argus couldn't read."
        }
    }

    /// One short line for the in-app price banner.
    var bannerText: String {
        switch self {
        case .rateLimited:  "Live prices are rate-limited right now."
        case .unreachable:  "No connection — showing the last prices Argus had."
        case .http, .malformed: "Live prices are unavailable right now."
        }
    }
}

/// Thin CoinGecko client. The top markets by market cap give us live prices and
/// a searchable universe of essentially every coin a user actually holds.
///
/// Works keyless, but sends a demo API key when one is baked into the build
/// (`COINGECKO_API_KEY`). Keyless requests share a per-IP quota, so they fail
/// exactly when many clients behind one address hit the endpoint at once.
enum CoinGecko {
    private static var apiKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "COINGECKO_API_KEY") as? String
        else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded "$(COINGECKO_API_KEY)" means no key was injected.
        return key.isEmpty || key.hasPrefix("$(") ? nil : key
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("crypto-ledger", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let apiKey { req.setValue(apiKey, forHTTPHeaderField: "x-cg-demo-api-key") }
        return req
    }

    /// One GET, with a single retry for the failures that are worth retrying
    /// (rate limit, 5xx). Throws a typed error so callers can say what broke.
    private static func fetch(_ url: URL, attempt: Int = 0) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            switch code {
            case 200..<300:
                return data
            case 429, 500...599:
                guard attempt < 1 else {
                    throw code == 429 ? CoinGeckoError.rateLimited : CoinGeckoError.http(code)
                }
                try? await Task.sleep(for: .seconds(code == 429 ? 3 : 1))
                return try await fetch(url, attempt: attempt + 1)
            default:
                throw CoinGeckoError.http(code)
            }
        } catch let error as CoinGeckoError {
            throw error
        } catch {
            throw CoinGeckoError.unreachable(error.localizedDescription)
        }
    }

    /// Fetch the top `pages * perPage` coins by market cap (default top 1000).
    /// Page 1 is load-bearing — if it fails the caller gets the reason. The
    /// deeper pages are best-effort coverage for long-tail holdings.
    static func topMarkets(pages: Int = 4, perPage: Int = 250) async throws -> [CoinMarket] {
        let first = try await marketsPage(page: 1, perPage: perPage)
        guard pages > 1 else { return first }
        let rest = await withTaskGroup(of: [CoinMarket].self) { group in
            for page in 2...pages {
                group.addTask { (try? await marketsPage(page: page, perPage: perPage)) ?? [] }
            }
            var all: [CoinMarket] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
        return (first + rest).sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
    }

    /// Best-effort fetch of a page range — used for background coverage top-up,
    /// where a failure is not worth reporting.
    static func markets(pages: ClosedRange<Int>, perPage: Int = 250) async -> [CoinMarket] {
        await withTaskGroup(of: [CoinMarket].self) { group in
            for page in pages {
                group.addTask { (try? await marketsPage(page: page, perPage: perPage)) ?? [] }
            }
            var all: [CoinMarket] = []
            for await chunk in group { all.append(contentsOf: chunk) }
            return all
        }
    }

    private static func marketsPage(page: Int, perPage: Int) async throws -> [CoinMarket] {
        var comps = URLComponents(string: "https://api.coingecko.com/api/v3/coins/markets")!
        comps.queryItems = [
            .init(name: "vs_currency", value: "usd"),
            .init(name: "order", value: "market_cap_desc"),
            .init(name: "per_page", value: String(perPage)),
            .init(name: "page", value: String(page)),
        ]
        guard let url = comps.url else { throw CoinGeckoError.malformed }
        do {
            let data = try await fetch(url)
            guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { throw CoinGeckoError.malformed }
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
        } catch let error as CoinGeckoError {
            throw error
        } catch {
            throw CoinGeckoError.unreachable(error.localizedDescription)
        }
    }

    /// Daily USD price history for one coin (by CoinGecko id), for the detail
    /// chart. Returns [] on any failure — a missing sparkline degrades to a
    /// hidden chart, which is honest, unlike a missing price.
    static func priceHistory(coinID: String, days: Int = 30) async -> [PricePoint] {
        var comps = URLComponents(string: "https://api.coingecko.com/api/v3/coins/\(coinID)/market_chart")!
        comps.queryItems = [
            .init(name: "vs_currency", value: "usd"),
            .init(name: "days", value: String(days)),
        ]
        guard let url = comps.url else { return [] }
        do {
            let data = try await fetch(url)
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

    /// Why the last fetch failed, if it did. Drives the visible price banner —
    /// prices that failed to load must never be mistaken for prices of zero.
    private(set) var lastError: CoinGeckoError?

    /// Which provider the prices on screen came from, and when.
    private(set) var source: PriceSource?
    private(set) var lastUpdated: Date?

    /// Seed from the last saved list, then refresh. A launch with no network
    /// opens on real (if stale) prices instead of an empty screen.
    func load() async {
        guard !loadedOnce, !isLoading else { return }
        if coins.isEmpty, let cached = CoinCache.load() {
            coins = cached.coins
            source = .cache
            lastUpdated = cached.savedAt
        }
        await fetchCoins()
    }

    /// Force a fresh price fetch — used when the app returns to the foreground
    /// so holdings and alerts are checked against current quotes. Keeps the
    /// coins already on screen if the refresh fails.
    func reload() async {
        guard !isLoading else { return }
        await fetchCoins()
    }

    /// Explicit user-driven retry from the price banner.
    func retry() async {
        loadedOnce = false
        await fetchCoins()
    }

    /// The largest coins by market cap — the live content a brand-new install
    /// shows before the user has entered anything at all.
    func topCoins(_ count: Int = 8) -> [CoinMarket] { Array(coins.prefix(count)) }

    /// Try the good source, then the keyless one, then keep whatever is already
    /// on screen. Only the case where all three come up empty is an error the
    /// user needs to see.
    ///
    /// Launch costs ONE request, not four: 250 coins covers the market card and
    /// essentially every coin a person actually holds. Deeper pages arrive via
    /// `extendCoverage()` once the screen is already useful — the difference
    /// between fitting inside an anonymous rate limit and blowing through it.
    private func fetchCoins() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let fresh = try await CoinGecko.topMarkets(pages: 1)
            guard !fresh.isEmpty else { throw CoinGeckoError.malformed }
            apply(fresh, from: .coinGecko)
            return
        } catch let error as CoinGeckoError {
            lastError = error
        } catch {
            lastError = .unreachable(error.localizedDescription)
        }

        // CoinGecko is unavailable — most often its per-IP anonymous quota.
        if let fallback = try? await Coinpaprika.topMarkets(), !fallback.isEmpty {
            apply(fallback, from: .coinpaprika)
            return
        }

        // Nothing reachable. Cached prices (already on screen from `load()`) are
        // better than a blank portfolio; the banner explains why they're stale.
        if !coins.isEmpty, lastUpdated == nil { lastUpdated = CoinCache.load()?.savedAt }
    }

    private func apply(_ fresh: [CoinMarket], from source: PriceSource) {
        coins = fresh
        loadedOnce = true
        lastError = nil
        self.source = source
        lastUpdated = Date()
        CoinCache.save(fresh, source: source)
    }

    /// Long-tail coverage (ranks ~250–1000), fetched after the first render and
    /// merged in. Best-effort: failure here costs nothing a user would notice.
    func extendCoverage() async {
        guard source == .coinGecko, coins.count < 600 else { return }
        let deeper = await CoinGecko.markets(pages: 2...4)
        guard !deeper.isEmpty else { return }
        var seen = Set(coins.map(\.id))
        var merged = coins
        for coin in deeper where !seen.contains(coin.id) {
            seen.insert(coin.id)
            merged.append(coin)
        }
        coins = merged.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
        CoinCache.save(coins, source: .coinGecko)
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
                    Text(coin.priceUSD, format: PriceFormat.usd(coin.priceUSD))
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
                    ContentUnavailableView {
                        Label("Couldn't load prices", systemImage: "wifi.slash")
                    } description: {
                        Text(catalog.lastError?.errorDescription
                             ?? "Check your connection and try again — you can still type a symbol by hand.")
                    } actions: {
                        Button("Try again") { Task { await catalog.retry() } }
                            .buttonStyle(.borderedProminent)
                    }
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

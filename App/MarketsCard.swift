import SwiftUI

/// Live top-of-market prices.
///
/// This is what a brand-new install shows before the user has entered a single
/// holding: real data, fetched on launch, tappable as the fastest on-ramp into
/// "I own some of that". An app whose first screen is an empty form asks the
/// person opening it to do work before it does anything — including whoever
/// reviews it.
struct MarketsCard: View {
    var catalog: CoinCatalog
    var count: Int = 8
    var onPick: (CoinMarket) -> Void

    var body: some View {
        Card(title: "Market today", systemImage: "chart.bar.fill") {
            let coins = catalog.topCoins(count)
            if !coins.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(coins.enumerated()), id: \.element.id) { i, coin in
                        if i > 0 { Divider() }
                        row(coin)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tap a coin to add it to your portfolio.")
                    // Say which source the numbers came from. When the app falls
                    // back to a second provider the prices shift slightly, and
                    // an unexplained shift reads as a bug.
                    if let source = catalog.source, let at = catalog.lastUpdated {
                        Text("Prices from \(source.displayName) · \(at, format: .dateTime.hour().minute())")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 8)
            } else if catalog.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading live prices…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                unavailable
            }
        }
    }

    private func row(_ coin: CoinMarket) -> some View {
        Button { onPick(coin) } label: {
            HStack(spacing: 12) {
                AssetBadge(symbol: coin.symbol, imageURL: coin.imageURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coin.symbol).fontWeight(.semibold).foregroundStyle(.primary)
                    Text(coin.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(coin.priceUSD, format: PriceFormat.usd(coin.priceUSD))
                    .monospacedDigit().fontWeight(.medium).foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    /// Prices failed to load. Say so, and offer the retry — never render this as
    /// an empty list, which reads as "there is nothing here".
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(catalog.lastError?.bannerText ?? "Live prices are unavailable right now.",
                  systemImage: "wifi.slash")
                .font(.callout).foregroundStyle(.secondary)
            Button("Try again") { Task { await catalog.retry() } }
                .buttonStyle(.bordered)
                .tint(Theme.amber)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// A one-line "prices didn't load" notice for screens that already have content.
/// Holdings priced from a stale or missing quote are still shown — the banner
/// explains why the numbers may not be current instead of leaving the user to
/// guess whether their portfolio really is worth that.
struct PriceStatusBanner: View {
    var catalog: CoinCatalog

    var body: some View {
        if let error = catalog.lastError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber)
                Text(error.bannerText)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if catalog.isLoading {
                    ProgressView()
                } else {
                    Button("Retry") { Task { await catalog.retry() } }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(14)
            .background(Theme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

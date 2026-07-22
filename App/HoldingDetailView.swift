import SwiftUI
import LedgerCore

/// Tap-through detail for one holding — logo, live price, your position, and a
/// per-coin news feed (Stocks-app style).
struct HoldingDetailView: View {
    let position: Position
    let name: String
    let imageURL: URL?

    @Environment(\.openURL) private var openURL
    @State private var news: [NewsItem] = []
    @State private var loadingNews = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                positionCard
                newsCard
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(Color.primary.opacity(0.03).ignoresSafeArea())
        .navigationTitle(position.assetID)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            news = await News.fetch(query: "\(name) crypto")
            loadingNews = false
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AssetBadge(symbol: position.assetID, size: 60, imageURL: imageURL)
            VStack(spacing: 2) {
                Text(name).font(.title3.weight(.semibold))
                Text(position.assetID).font(.subheadline).foregroundStyle(.secondary)
            }
            if let price = position.spotUSD {
                Text(price, format: .currency(code: "USD"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("per \(position.assetID)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var positionCard: some View {
        Card(title: "Your position", systemImage: "chart.pie") {
            statRow("Holdings", "\(position.qty.formatted(.number.precision(.significantDigits(1...8)))) \(position.assetID)")
            Divider()
            if let v = position.marketValueUSD {
                statRow("Market value", v.formatted(.currency(code: "USD")))
                Divider()
            }
            statRow("Cost basis", position.costBasisUSD.formatted(.currency(code: "USD")))
            if let u = position.unrealizedUSD {
                Divider()
                HStack {
                    Text("Unrealized").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(u >= 0 ? "+" : "")\(u.formatted(.currency(code: "USD")))")
                        .monospacedDigit().fontWeight(.semibold)
                        .foregroundStyle(u >= 0 ? .green : .red)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private var newsCard: some View {
        Card(title: "\(name) news", systemImage: "newspaper") {
            if loadingNews {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading headlines…").foregroundStyle(.secondary).font(.subheadline)
                }
                .padding(.vertical, 6)
            } else if news.isEmpty {
                Text("No recent headlines found.")
                    .foregroundStyle(.secondary).font(.subheadline).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(news.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider() }
                        Button { openURL(item.url) } label: { newsRow(item) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func newsRow(_ item: NewsItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.callout).fontWeight(.medium)
                    .multilineTextAlignment(.leading).lineLimit(3)
                HStack(spacing: 6) {
                    Text(item.source).foregroundStyle(.secondary)
                    if let d = item.published {
                        Text("·").foregroundStyle(.tertiary)
                        Text(d, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 3)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

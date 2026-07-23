import SwiftUI
import LedgerCore

/// Tap-through detail for one holding — logo, live price, your position, and a
/// per-coin news feed (Stocks-app style).
struct HoldingDetailView: View {
    let position: Position
    let name: String
    let imageURL: URL?
    var alerts: AlertStore

    @Environment(\.openURL) private var openURL
    @State private var news: [NewsItem] = []
    @State private var loadingNews = true
    @State private var showingAddAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                positionCard
                alertsCard
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
        .sheet(isPresented: $showingAddAlert) {
            AddAlertView(assetID: position.assetID, currentPrice: position.spotUSD) { alert in
                alerts.add(alert)
            }
        }
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

    // MARK: - Price alerts

    private var alertsCard: some View {
        let list = alerts.alerts(for: position.assetID)
        return Card(title: "Price alerts", systemImage: "bell") {
            if list.isEmpty {
                Text("Get a notification when \(position.assetID) hits a price you care about — even when Argus is closed.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, alert in
                        if i > 0 { Divider() }
                        alertRow(alert)
                    }
                }
            }

            if alerts.permission == .denied {
                Label("Notifications are off. Turn them on in Settings › Argus to receive alerts.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.top, 2)
            }

            Button {
                showingAddAlert = true
            } label: {
                Label("Add price alert", systemImage: "bell.badge")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.indigo)
            .padding(.top, 4)
        }
    }

    private func alertRow(_ alert: PriceAlert) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((alert.isActive ? Color.indigo : Color.secondary).opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: alert.direction.icon)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(alert.isActive ? Color.indigo : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(alert.direction.label) \(alert.targetUSD.formatted(.currency(code: "USD")))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(alert.isActive ? .primary : .secondary)
                Text(alert.isActive ? "Active" : "Triggered")
                    .font(.caption).foregroundStyle(alert.isActive ? .green : .secondary)
            }
            Spacer()
            if !alert.isActive {
                Button("Re-arm") { alerts.setActive(alert, true) }
                    .buttonStyle(.bordered).tint(.indigo).controlSize(.small)
            }
            Button(role: .destructive) { alerts.remove(alert) } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
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

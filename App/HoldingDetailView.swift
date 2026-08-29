import SwiftUI
import LedgerCore

/// Tap-through detail for one holding — logo, live price, your position, and a
/// per-coin news feed (Stocks-app style).
struct HoldingDetailView: View {
    let position: Position
    let name: String
    let imageURL: URL?
    /// CoinGecko id for this coin, when the catalogue knows one. Nil for
    /// anything the catalogue could not resolve (an imported token with no
    /// market feed), in which case the price chart is simply not shown.
    var coinID: String?
    var alerts: AlertStore
    var store: PortfolioStore

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var news: [NewsItem] = []
    @State private var loadingNews = true
    @State private var showingAddAlert = false
    @State private var showingEdit = false
    @State private var history: [PricePoint] = []
    @State private var loadingHistory = false
    @State private var range: PriceRange = .month

    /// Windows offered under the price chart. CoinGecko returns daily points
    /// for all of these on the free tier.
    enum PriceRange: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week: "1W"
            case .month: "1M"
            case .quarter: "3M"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                priceCard
                positionCard
                alertsCard
                newsCard
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(position.assetID)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingEdit = true } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showingAddAlert) {
            AddAlertView(assetID: position.assetID, currentPrice: position.spotUSD) { alert in
                alerts.add(alert)
            }
        }
        .sheet(isPresented: $showingEdit) {
            EditHoldingView(position: position) { qty, unitCost in
                store.setHolding(assetID: position.assetID, quantity: qty, unitCostUSD: unitCost)
                dismiss()   // pop back; the list re-renders from the new snapshot
            } onDelete: {
                store.removeAsset(position.assetID)
                dismiss()
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
                Text(price, format: PriceFormat.usd(price))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("per \(position.assetID)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// Price history for this coin.
    ///
    /// Reuses NetWorthChart rather than drawing a second chart: the two show
    /// the same shape of thing, and a portfolio app with two different-looking
    /// line charts reads as two different apps. PricePoint and NetWorthPoint
    /// are both (date, value), so the mapping is the whole adapter.
    ///
    /// Hidden entirely when there is no history — for a coin the catalogue
    /// cannot resolve, or when CoinGecko is rate-limiting. An empty frame that
    /// says "chart unavailable" is worse than a screen that never promised one.
    @ViewBuilder
    private var priceCard: some View {
        if coinID != nil, loadingHistory || history.count >= 2 {
            Card(title: "Price", systemImage: "chart.xyaxis.line") {
                Picker("Range", selection: $range) {
                    ForEach(PriceRange.allCases) { r in Text(r.label).tag(r) }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 4)

                if history.count >= 2 {
                    NetWorthChart(points: chartPoints)
                    .frame(height: 148)
                    Text("\(range.label) · CoinGecko")
                        .font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                } else {
                    // Reserve the chart's height so switching range does not
                    // make the cards below jump around under the finger.
                    ProgressView().frame(maxWidth: .infinity).frame(height: 148)
                }
            }
            .task(id: "\(coinID ?? "")#\(range.rawValue)") { await loadHistory() }
        }
    }

    /// History mapped for the chart, thinned to something a 148pt-tall view can
    /// actually use.
    ///
    /// CoinGecko's window is not daily despite what the API docs imply: under
    /// 90 days it returns hourly points, so "90D" arrives as ~2,161 samples —
    /// about fifteen per horizontal pixel. Drawing them all costs memory and
    /// makes the scrub crosshair jitter between samples that render on the
    /// same column. Keep the first and last so the endpoints stay exact, and
    /// stride the middle.
    private var chartPoints: [NetWorthPoint] {
        let mapped = history.map { NetWorthPoint(date: $0.date, value: $0.priceUSD) }
        let maxPoints = 180
        guard mapped.count > maxPoints else { return mapped }
        let stride = Int((Double(mapped.count) / Double(maxPoints)).rounded(.up))
        var thinned = mapped.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
        if let last = mapped.last, thinned.last?.date != last.date { thinned.append(last) }
        return thinned
    }

    private func loadHistory() async {
        guard let id = coinID else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        history = await CoinGecko.priceHistory(coinID: id, days: range.rawValue)
    }

    private var positionCard: some View {
        Card(title: "Your position", systemImage: "chart.pie") {
            statRow("Holdings", "\(position.qty.formatted(.number.precision(.significantDigits(1...8)))) \(position.assetID)")
            // The row above is the pooled total. Staked and wallet balances are
            // the same asset to the tax engine but not to the person holding
            // them, so break the total back down by where it actually sits.
            ForEach(position.byAccount) { part in
                HStack {
                    Text(part.accountID)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(part.qty.formatted(.number.precision(.significantDigits(1...8))))
                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.leading, 12)
                .padding(.vertical, 2)
            }
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
                        .foregroundStyle(u >= 0 ? Theme.gain : Theme.loss)
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
                Text("Get a notification when \(position.assetID) hits a price you care about. Argus checks in the background — iOS decides how often — and again whenever you open it.")
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
            .foregroundStyle(Theme.amber)
            .padding(.top, 4)
        }
    }

    private func alertRow(_ alert: PriceAlert) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((alert.isActive ? Theme.amber : Color.secondary).opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: alert.direction.icon)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(alert.isActive ? Theme.amber : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(alert.direction.label) \(alert.targetUSD.formatted(PriceFormat.usd(alert.targetUSD)))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(alert.isActive ? .primary : .secondary)
                Text(alert.isActive ? "Active" : "Triggered")
                    .font(.caption).foregroundStyle(alert.isActive ? Theme.gain : Color.secondary)
            }
            Spacer()
            if !alert.isActive {
                Button("Re-arm") { alerts.setActive(alert, true) }
                    .buttonStyle(.bordered).tint(Theme.amber).controlSize(.small)
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

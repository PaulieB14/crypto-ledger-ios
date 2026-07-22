import SwiftUI
import LedgerCore

struct NetWorthView: View {
    @State private var store = PortfolioStore.fixtures()
    @State private var catalog = CoinCatalog()
    @State private var showingAdd = false
    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            Group {
                switch store.state {
                case .idle, .loading:
                    ProgressView("Loading your portfolio…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load your accounts",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message))
                case .loaded:
                    if let snapshot = store.snapshot {
                        loaded(snapshot)
                    } else {
                        emptyState
                    }
                }
            }
            .navigationTitle("Portfolio")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showingAdd = true } label: {
                            Label("New transaction", systemImage: "plus")
                        }
                        Button { showingImport = true } label: {
                            Label("Import CSV…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddTransactionView(catalog: catalog) { draft in
                    store.addTransaction(draft)
                    store.refreshPrices(from: catalog.spotMap)
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportView { drafts in
                    store.addTransactions(drafts)
                    store.refreshPrices(from: catalog.spotMap)
                }
            }
            .task {
                await store.load()
                await catalog.load()
                store.refreshPrices(from: catalog.spotMap)
            }
        }
        .tint(.indigo)
    }

    // MARK: - Loaded

    private func loaded(_ s: PortfolioSnapshot) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                HeroCard(snapshot: s)

                if s.hasOpenQuestions {
                    reviewCard(s)
                }

                holdingsCard(s)
                realizedCard(s)
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(backdrop)
    }

    private func holdingsCard(_ s: PortfolioSnapshot) -> some View {
        Card(title: "Holdings", systemImage: "circle.grid.2x2") {
            if s.positions.isEmpty {
                Text("No open positions yet. Tap ")
                    + Text(Image(systemName: "plus.circle.fill")).foregroundColor(.indigo)
                    + Text(" to add one.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(s.positions.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider() }
                        HoldingRow(position: p)
                    }
                    if s.cashUSD != 0 {
                        Divider()
                        cashRow(s.cashUSD)
                    }
                }
            }
        }
    }

    private func cashRow(_ cash: Decimal) -> some View {
        HStack(spacing: 12) {
            AssetBadge(symbol: "USD")
            Text("Cash").fontWeight(.medium)
            Spacer()
            Text(cash, format: .currency(code: "USD"))
                .monospacedDigit().fontWeight(.medium)
        }
        .padding(.vertical, 8)
    }

    private func realizedCard(_ s: PortfolioSnapshot) -> some View {
        Card(title: "Realized gains", systemImage: "chart.line.uptrend.xyaxis") {
            stat("Short term", s.realizedShortTermUSD)
            Divider()
            stat("Long term", s.realizedLongTermUSD)
            Divider()
            Picker("Cost basis", selection: $store.method) {
                ForEach(CostBasisMethod.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .padding(.top, 2)
            Text("Changing the method moves gains between realized and unrealized. It never changes what you own.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: Decimal) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value, format: .currency(code: "USD"))
                .monospacedDigit()
                .foregroundStyle(value >= 0 ? Color.primary : .red)
        }
        .padding(.vertical, 4)
    }

    private func reviewCard(_ s: PortfolioSnapshot) -> some View {
        let count = s.transfersNeedingReview.count + s.unpairedTransfers.count
        return NavigationLink {
            ReviewQueueView(snapshot: s)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) item\(count == 1 ? "" : "s") need review")
                        .fontWeight(.semibold).foregroundStyle(.primary)
                    Text("Totals stay incomplete until you resolve them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No transactions yet", systemImage: "tray")
        } description: {
            Text("Add a purchase, a deposit, or crypto you received to start tracking your net worth.")
        } actions: {
            Button {
                showingAdd = true
            } label: {
                Label("Add your first transaction", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var backdrop: some View {
        Color.primary.opacity(0.03).ignoresSafeArea()
    }
}

// MARK: - Hero balance card

private struct HeroCard: View {
    let snapshot: PortfolioSnapshot

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("NET WORTH")
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                Text(snapshot.netWorthUSD, format: .currency(code: "USD"))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if snapshot.cryptoValueUSD != 0 {
                    changeChip
                }
            }

            HStack(spacing: 12) {
                tile("Cash", snapshot.cashUSD, "banknote.fill")
                tile("Crypto", snapshot.cryptoValueUSD, "bitcoinsign.circle.fill")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color(hue: 0.66, saturation: 0.62, brightness: 0.62),
                         Color(hue: 0.74, saturation: 0.58, brightness: 0.5)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .indigo.opacity(0.3), radius: 14, y: 8)
    }

    private var changeChip: some View {
        let up = snapshot.unrealizedUSD >= 0
        return HStack(spacing: 4) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
            Text(snapshot.unrealizedUSD, format: .currency(code: "USD"))
                .monospacedDigit()
            Text("unrealized").opacity(0.8)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.white.opacity(0.18), in: Capsule())
    }

    private func tile(_ label: String, _ value: Decimal, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            Text(value, format: .currency(code: "USD"))
                .font(.headline).monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Holding row

private struct HoldingRow: View {
    let position: Position

    var body: some View {
        HStack(spacing: 12) {
            AssetBadge(symbol: position.assetID)
            VStack(alignment: .leading, spacing: 2) {
                Text(position.assetID).fontWeight(.semibold)
                Text(position.qty.formatted(.number.precision(.significantDigits(1...8))))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let value = position.marketValueUSD {
                    Text(value, format: .currency(code: "USD"))
                        .monospacedDigit().fontWeight(.medium)
                } else {
                    Text("No price").foregroundStyle(.secondary)
                }
                if let unrealized = position.unrealizedUSD {
                    Text(unrealized, format: .currency(code: "USD"))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(unrealized >= 0 ? .green : .red)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Card container

private struct Card<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(.indigo)
                }
                Text(title).font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

// MARK: - Review queue

private struct ReviewQueueView: View {
    let snapshot: PortfolioSnapshot

    var body: some View {
        List {
            if !snapshot.transfersNeedingReview.isEmpty {
                Section("Possible transfers") {
                    ForEach(snapshot.transfersNeedingReview, id: \.self) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(candidate.outbound.accountID) → \(candidate.inbound.accountID)")
                                .font(.body.weight(.medium))
                            Text("\(candidate.outbound.assetID) · \(Int(candidate.confidence * 100))% confident")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !snapshot.unpairedTransfers.isEmpty {
                Section {
                    ForEach(snapshot.unpairedTransfers) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.assetID) · \(entry.accountID)")
                                .font(.body.weight(.medium))
                            Text(entry.timestamp, format: .dateTime.year().month().day())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("No matching account")
                } footer: {
                    Text("These moved in or out without a counterpart. Connect the other account, or mark them as a purchase or sale.")
                }
            }
        }
        .navigationTitle("Review")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if os(iOS)
#Preview {
    NetWorthView()
}
#endif

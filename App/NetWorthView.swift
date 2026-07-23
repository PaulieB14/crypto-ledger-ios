import SwiftUI
import LedgerCore

struct NetWorthView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = PortfolioStore.live()
    @State private var catalog = CoinCatalog()
    @State private var alerts = AlertStore()
    @State private var showingBalance = false
    @State private var showingWallet = false
    @State private var showingAdd = false
    @State private var showingImport = false
    @State private var showingHelp = false

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
                        Section("Add what you own") {
                            Button { showingBalance = true } label: {
                                Label("Add holding", systemImage: "chart.pie.fill")
                            }
                            Button { showingWallet = true } label: {
                                Label("Import from wallet", systemImage: "wallet.pass")
                            }
                            Button { showingAdd = true } label: {
                                Label("Add transaction", systemImage: "arrow.left.arrow.right")
                            }
                            Button { showingImport = true } label: {
                                Label("Import CSV…", systemImage: "square.and.arrow.down")
                            }
                        }
                        if store.snapshot != nil {
                            Button(role: .destructive) { store.clearAll() } label: {
                                Label("Clear all", systemImage: "trash")
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { showingHelp = true } label: {
                        Label("How it works", systemImage: "questionmark.circle")
                    }
                }
            }
            .sheet(isPresented: $showingBalance) {
                AddTransactionView(catalog: catalog, lockedKind: .balance) { draft in
                    store.addTransaction(draft)
                    store.refreshPrices(from: catalog.spotMap)
                }
            }
            .sheet(isPresented: $showingWallet) {
                WalletImportView(catalog: catalog) { drafts in
                    store.addTransactions(drafts)
                    store.refreshPrices(from: catalog.spotMap)
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
            .sheet(isPresented: $showingHelp) {
                HelpView()
            }
            .task {
                alerts.load()
                await store.load()
                await catalog.load()
                store.refreshPrices(from: catalog.spotMap)
                alerts.evaluate(spot: catalog.spotMap)
                await store.reconstructHistory(coinIDBySymbol: catalog.coinIDMap())
            }
            .onChange(of: scenePhase) { _, phase in
                // Returning to the app is a good moment to re-price and re-check
                // alerts against the latest quotes.
                if phase == .active {
                    Task {
                        await catalog.reload()
                        store.refreshPrices(from: catalog.spotMap)
                        alerts.evaluate(spot: catalog.spotMap)
                    }
                }
            }
        }
        .tint(Theme.amber)
    }

    // MARK: - Loaded

    private func loaded(_ s: PortfolioSnapshot) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                HeroCard(snapshot: s, points: store.historyPoints)

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
                    + Text(Image(systemName: "plus.circle.fill")).foregroundColor(Theme.amber)
                    + Text(" to add one.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(s.positions.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider() }
                        NavigationLink {
                            HoldingDetailView(position: p,
                                              name: catalog.name(for: p.assetID),
                                              imageURL: catalog.imageURL(for: p.assetID),
                                              alerts: alerts,
                                              store: store)
                        } label: {
                            HoldingRow(position: p, imageURL: catalog.imageURL(for: p.assetID))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeAsset(p.assetID)
                            } label: {
                                Label("Remove \(p.assetID)", systemImage: "trash")
                            }
                        }
                    }
                    if s.cashUSD > 0 {
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
                .foregroundStyle(value >= 0 ? Theme.ink : Theme.loss)
        }
        .padding(.vertical, 4)
    }

    private func reviewCard(_ s: PortfolioSnapshot) -> some View {
        let count = s.transfersNeedingReview.count + s.unpairedTransfers.count
            + s.uncoveredDisposals.count + s.unpricedAcquisitions.count
            + s.assetsMissingPrice.count
        return NavigationLink {
            ReviewQueueView(snapshot: s)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2).foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) item\(count == 1 ? "" : "s") \(count == 1 ? "needs" : "need") review")
                        .fontWeight(.semibold).foregroundStyle(.primary)
                    Text("Totals stay incomplete until you resolve them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty / onboarding

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Theme.amber)
                        .padding(.top, 8)
                    Text("Track your crypto net worth")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Start with what you have. Pick the way that's easiest — you can always add more later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)

                VStack(spacing: 12) {
                    onRamp(1, "Add what you hold",
                           "Just enter how much of each coin you own. Simplest.") {
                        showingBalance = true
                    }
                    onRamp(2, "Log your buys & sells",
                           "Enter transactions to track cost basis and real gains.") {
                        showingAdd = true
                    }
                    onRamp(3, "Import a CSV",
                           "Bring your full history from an exchange. Most complete.") {
                        showingImport = true
                    }
                }

                walletImportButton

                VStack(spacing: 10) {
                    Button {
                        store.loadSample()
                        Task { await store.reconstructHistory(coinIDBySymbol: catalog.coinIDMap()) }
                    } label: {
                        Text("Preview with sample data")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.amber)

                    Text("Everything stays on your device.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(backdrop)
    }

    /// The effortless version of step 1: paste an address, auto-fill holdings.
    private var walletImportButton: some View {
        Button {
            showingWallet = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.amber.opacity(0.14)).frame(width: 40, height: 40)
                    Image(systemName: "wallet.pass").font(.headline).foregroundStyle(Theme.amber)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import from a wallet").font(.headline).foregroundStyle(.primary)
                    Text("Paste an address — Argus fills in step 1 for you, across chains.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(Theme.amber.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// A single tap-to-start onboarding row. The number encodes a real
    /// progression — easiest first, most complete last.
    private func onRamp(_ number: Int, _ title: String, _ subtitle: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.amber.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Text("\(number)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.amber)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var backdrop: some View {
        Theme.paper.ignoresSafeArea()
    }
}

// MARK: - Hero balance card

private struct HeroCard: View {
    let snapshot: PortfolioSnapshot
    let points: [NetWorthPoint]

    @State private var scrubbed: NetWorthPoint?

    private var currentValue: Double {
        scrubbed?.value ?? (snapshot.netWorthUSD as NSDecimalNumber).doubleValue
    }
    private var openValue: Double { points.first?.value ?? currentValue }
    private var delta: Double { currentValue - openValue }
    private var pct: Double { openValue != 0 ? delta / openValue * 100 : 0 }
    private var up: Bool { delta >= 0 }
    private var dateline: Date { scrubbed?.date ?? snapshot.asOf }
    private var unpricedCount: Int {
        snapshot.assetsMissingPrice.count + snapshot.unpricedAcquisitions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: freshness dot + rubric, with the editorial dateline.
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Theme.amber).frame(width: 7, height: 7)
                    Text("NET WORTH").font(.rubric()).tracking(0.8)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Text("as of \(dateline, format: .dateTime.hour().minute())")
                    .font(.editorial(12)).foregroundStyle(Theme.inkSecondary)
            }

            // The figure — neutral Ink, never colored; a dagger if we exclude anything.
            HStack(alignment: .top, spacing: 1) {
                Text(currentValue, format: .currency(code: "USD"))
                    .font(.figure(42, .medium)).monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.ink)
                    .minimumScaleFactor(0.5).lineLimit(1)
                if unpricedCount > 0 {
                    Text("†").font(.figure(18)).foregroundStyle(Theme.amber)
                }
            }

            // Delta — the only place color is spent on the headline.
            if points.count >= 2 {
                HStack(spacing: 8) {
                    Image(systemName: up ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                    Text(abs(delta), format: .currency(code: "USD")).monospacedDigit()
                    Text("\(up ? "+" : "-")\(abs(pct), format: .number.precision(.fractionLength(2)))%")
                        .monospacedDigit()
                }
                .font(.figure(15, .medium))
                .foregroundStyle(up ? Theme.gain : Theme.loss)
            }

            NetWorthChart(points: points) { p in scrubbed = p }
                .frame(height: 148)

            allocationBar

            if unpricedCount > 0 {
                Text("† excludes \(unpricedCount) unpriced asset\(unpricedCount == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hairline, lineWidth: 1))
    }

    // 100%-stacked hairline allocation bar — cash vs crypto.
    private var allocationBar: some View {
        let cash = max(0, (snapshot.cashUSD as NSDecimalNumber).doubleValue)
        let crypto = max(0, (snapshot.cryptoValueUSD as NSDecimalNumber).doubleValue)
        let total = cash + crypto
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: total > 0 ? 1 : 0) {
                    if total > 0 {
                        Rectangle().fill(Theme.ink)
                            .frame(width: geo.size.width * crypto / total)
                        Rectangle().fill(Theme.inkSecondary)
                            .frame(width: geo.size.width * cash / total)
                    } else {
                        Rectangle().fill(Theme.hairline)
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())

            HStack(spacing: 18) {
                legend(Theme.ink, "CRYPTO", crypto)
                legend(Theme.inkSecondary, "CASH", cash)
                Spacer()
            }
        }
    }

    private func legend(_ color: Color, _ label: String, _ value: Double) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.rubric(10)).tracking(0.5).foregroundStyle(Theme.inkSecondary)
            Text(value, format: .currency(code: "USD").precision(.fractionLength(0)))
                .font(.figure(12)).monospacedDigit().foregroundStyle(Theme.ink)
        }
    }
}

// MARK: - Holding row

private struct HoldingRow: View {
    let position: Position
    var imageURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            AssetBadge(symbol: position.assetID, imageURL: imageURL)
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
                        .foregroundStyle(unrealized >= 0 ? Theme.gain : Theme.loss)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 1)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Card container

struct Card<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(Theme.amber)
                }
                Text(title).font(.headline).foregroundStyle(Theme.ink)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Review queue

private struct ReviewQueueView: View {
    let snapshot: PortfolioSnapshot

    var body: some View {
        List {
            if !snapshot.assetsMissingPrice.isEmpty {
                Section {
                    ForEach(snapshot.assetsMissingPrice, id: \.self) { symbol in
                        HStack(spacing: 12) {
                            AssetBadge(symbol: symbol, size: 28)
                            Text(symbol).font(.body.weight(.medium))
                            Spacer()
                            Text("No price").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("No live price")
                } footer: {
                    Text("We couldn't fetch a current price for these, so their value isn't counted yet. Check the symbol is right, or try again when you're back online.")
                }
            }

            if !snapshot.unpricedAcquisitions.isEmpty {
                Section {
                    ForEach(snapshot.unpricedAcquisitions) { entry in
                        reviewRow(entry.assetID, entry.timestamp, detail: entry.accountID)
                    }
                } header: {
                    Text("Missing purchase price")
                } footer: {
                    Text("These were added without a price, so they have no cost basis. Add one to see accurate gains.")
                }
            }

            if !snapshot.uncoveredDisposals.isEmpty {
                Section {
                    ForEach(snapshot.uncoveredDisposals) { entry in
                        reviewRow(entry.assetID, entry.timestamp, detail: entry.accountID)
                    }
                } header: {
                    Text("Sold more than we have on record")
                } footer: {
                    Text("We have no earlier purchase to draw a cost basis from for these sales. Add the buy that came before them.")
                }
            }

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
                        reviewRow(entry.assetID, entry.timestamp, detail: entry.accountID)
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

    private func reviewRow(_ assetID: String, _ date: Date, detail: String) -> some View {
        HStack(spacing: 12) {
            AssetBadge(symbol: assetID, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(assetID) · \(detail)").font(.body.weight(.medium))
                Text(date, format: .dateTime.year().month().day())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#if os(iOS)
#Preview {
    NetWorthView()
}
#endif

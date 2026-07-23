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
                        NavigationLink {
                            HoldingDetailView(position: p,
                                              name: catalog.name(for: p.assetID),
                                              imageURL: catalog.imageURL(for: p.assetID),
                                              alerts: alerts)
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
            + s.uncoveredDisposals.count + s.unpricedAcquisitions.count
            + s.assetsMissingPrice.count
        return NavigationLink {
            ReviewQueueView(snapshot: s)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2).foregroundStyle(.orange)
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
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
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
                        .foregroundStyle(.indigo)
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
                    Button { store.loadSample() } label: {
                        Text("Preview with sample data")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.indigo)

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
                    Circle().fill(Color.indigo.opacity(0.14)).frame(width: 40, height: 40)
                    Image(systemName: "wallet.pass").font(.headline).foregroundStyle(.indigo)
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
            .background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(Color.indigo.opacity(0.18), lineWidth: 1))
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
                    Circle().fill(Color.indigo.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Text("\(number)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.indigo)
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
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
                        .foregroundStyle(unrealized >= 0 ? .green : .red)
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

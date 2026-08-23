import Foundation
import Observation
import LedgerCore

@Observable
@MainActor
final class PortfolioStore {

    enum LoadState {
        case idle, loading, loaded, failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var snapshot: PortfolioSnapshot?

    /// Recorded daily net-worth history — the honest source for the hero chart.
    private(set) var history: [NetWorthSnapshot] = []

    /// Backfilled history reconstructed from the ledger × real price history
    /// (session-only, never persisted; recorded snapshots override it).
    private(set) var reconstructed: [NetWorthPoint] = []

    /// Merged chart series — reconstruction fills the past, recorded snapshots
    /// are authoritative for the days they cover.
    var historyPoints: [NetWorthPoint] {
        var byDay: [Date: NetWorthPoint] = [:]
        for p in reconstructed { byDay[p.date] = p }
        for s in history { byDay[s.date] = NetWorthPoint(date: s.date, value: s.netWorthUSD) }
        return byDay.values.sorted { $0.date < $1.date }
    }

    /// Symbol→id map from the last reconstruction, kept so the chart can be
    /// rebuilt when the ledger changes without waiting for the catalog again.
    private var lastCoinIDBySymbol: [String: String] = [:]

    /// Backfill the chart from the ledger × per-coin price history. Runs after
    /// the catalog loads (it needs symbol→id); safe to call again.
    func reconstructHistory(coinIDBySymbol: [String: String]) async {
        guard !coinIDBySymbol.isEmpty else { return }
        lastCoinIDBySymbol = coinIDBySymbol
        reconstructed = await NetWorthReconstruction.series(
            entries: allEntries, coinIDBySymbol: coinIDBySymbol)
    }

    /// Rebuild the chart after the ledger changes.
    ///
    /// Without this the only reconstruction happened in NetWorthView's `.task`,
    /// which fires once on appear — BEFORE the user has entered anything. A
    /// first-session user (or an App Reviewer) would add a holding and get the
    /// "Tracking since today" one-liner instead of a chart, and only see the
    /// real series after force-quitting and relaunching. The chart is the
    /// feature the App Store description leads with, so an empty one on first
    /// run reads as broken.
    private func rebuildHistoryAfterLedgerChange() {
        guard !lastCoinIDBySymbol.isEmpty else { return }
        let map = lastCoinIDBySymbol
        Task { await reconstructHistory(coinIDBySymbol: map) }
    }

    /// Count of transactions the user has entered this session (for the UI).
    private(set) var manualCount: Int = 0

    var method: CostBasisMethod = .fifo {
        didSet { recompute() }
    }

    private var sourceEntries: [LedgerEntry] = []
    private var manualEntries: [LedgerEntry] = []

    /// Working spot prices — seeded from the source in `load()`, then extended
    /// as the user adds assets. A plain `[:]` default means the `nonisolated`
    /// init never touches this main-actor-isolated property.
    private var spot: [String: Decimal] = [:]
    /// Positions the launch refresh moved, for a one-line note in the UI.
    private(set) var holdingUpdates: [String] = []

    private let initialSpot: [String: Decimal]
    private let aggregator: SourceAggregator
    private let initialError: String?

    /// `nonisolated` so SwiftUI can build one in a `@State` property
    /// initializer, which runs outside the main actor's isolation even though
    /// the view body is on it.
    nonisolated init(
        sources: [any PortfolioSource],
        spot: [String: Decimal] = [:],
        initialError: String? = nil
    ) {
        self.aggregator = SourceAggregator(sources: sources)
        self.initialSpot = spot
        self.initialError = initialError
    }

    /// A fresh, empty portfolio — the real app entry point. No demo data: a
    /// brand-new install opens at $0 and restores only the transactions the user
    /// entered themselves.
    nonisolated static func live() -> PortfolioStore {
        PortfolioStore(sources: [])
    }

    // PortfolioStore.fixtures() was deleted 2026-08-18. It built a store from
    // LedgerCore's fixtures.json — invented holdings — and had ZERO call sites,
    // but it was the last thing in the app target that could construct a
    // fabricated portfolio. The App Review Board reinstated this app on a
    // written statement that every path to fabricated data was gone; leaving a
    // dormant constructor around made that statement narrowly untrue.
    //
    // fixtures.json itself stays in LedgerCore: KnownAnswerTests loads it, and
    // it is inert data with no remaining code path in the shipped app.

    func load() async {
        if let initialError {
            state = .failed(initialError)
            return
        }
        state = .loading
        spot = initialSpot
        history = SnapshotStore.load()
        // Restore transactions the user entered in previous sessions, and seed
        // a fallback price from each so restored holdings show a value before
        // the live price refresh lands.
        manualEntries = LedgerStore.load()
        manualCount = manualEntries.count
        for e in manualEntries where e.assetID != "USD" {
            if let p = e.unitPriceUSD, p > 0, spot[e.assetID] == nil { spot[e.assetID] = p }
        }
        do {
            sourceEntries = try await aggregator.loadAll()
            recompute()
            state = .loaded
        } catch {
            // Even if the demo source fails, the user's own persisted entries stand.
            recompute()
            state = manualEntries.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }

    /// Append a user-entered transaction and re-derive everything. Additive and
    /// immutable-friendly: nothing is edited, the portfolio is just re-folded.
    func addTransaction(_ draft: TransactionDraft) {
        let new = draft.makeEntries()
        guard !new.isEmpty else { return }
        manualEntries.append(contentsOf: new)
        manualCount += 1
        if let seed = draft.spotSeed, spot[seed.asset] == nil {
            spot[seed.asset] = seed.price
        }
        recompute()
        state = .loaded
        LedgerStore.save(manualEntries)
        rebuildHistoryAfterLedgerChange()
    }

    /// Bulk-append transactions (e.g. a CSV import) and re-derive once.
    func addTransactions(_ drafts: [TransactionDraft]) {
        guard !drafts.isEmpty else { return }
        for d in drafts {
            manualEntries.append(contentsOf: d.makeEntries())
            if let seed = d.spotSeed, spot[seed.asset] == nil { spot[seed.asset] = seed.price }
        }
        manualCount += drafts.count
        recompute()
        state = .loaded
        LedgerStore.save(manualEntries)
        rebuildHistoryAfterLedgerChange()
    }

    /// Bring imported positions up to date: staked amounts, wallet balances, and
    /// prices for tokens the CoinGecko catalog cannot see.
    ///
    /// Deliberately runs after `load()` has already rendered. A vault query is
    /// quick but a token scan crosses twelve explorers, and none of it should sit
    /// between the user and their portfolio. Everything here degrades to "leave
    /// the stored numbers alone" rather than to zero.
    func refreshHoldings() async {
        var updates: [String] = []

        let staked = await HoldingsRefresh.reconcile(entries: manualEntries)
        if !staked.isEmpty {
            manualEntries = staked.entries
            updates += staked.changed.map(Self.describe)
        }

        let wallet = await HoldingsRefresh.reconcileWallet(entries: manualEntries)
        if !wallet.isEmpty {
            manualEntries = wallet.entries
            updates += wallet.changed.map(Self.describe)
        }

        // Prices for the long tail. Merged on top of the catalog rather than
        // under it, because a contract-addressed quote beats a symbol match.
        let contractPrices = await TokenRegistry.spotMap()
        for (symbol, price) in contractPrices where price > 0 { spot[symbol] = price }

        guard !updates.isEmpty || !contractPrices.isEmpty else { return }
        if !updates.isEmpty {
            manualCount = manualEntries.count
            holdingUpdates = updates
            LedgerStore.save(manualEntries)
            rebuildHistoryAfterLedgerChange()
        }
        recompute()
        state = .loaded
    }

    private static func describe(_ c: (account: String, from: Decimal, to: Decimal)) -> String {
        let f = { (d: Decimal) in d.formatted(.number.precision(.fractionLength(0...6))) }
        return "\(c.account): \(f(c.from)) → \(f(c.to))"
    }

    /// Merge live spot prices (e.g. from CoinGecko) and re-derive valuations.
    func refreshPrices(from map: [String: Decimal]) {
        guard !map.isEmpty else { return }
        for (symbol, price) in map where price > 0 { spot[symbol] = price }
        recompute()
    }

    /// Remove a holding entirely: every manual entry for the asset plus the
    /// paired cash legs of its trades (matched by `groupID`). Immutable-friendly
    /// — nothing is edited, the deleted facts are simply dropped and the
    /// portfolio re-folded. Demo/source entries aren't touched.
    func removeAsset(_ assetID: String) {
        let groups = Set(manualEntries.filter { $0.assetID == assetID }.compactMap(\.groupID))
        let before = manualEntries.count
        manualEntries.removeAll { e in
            e.assetID == assetID || (e.groupID.map(groups.contains) ?? false)
        }
        guard manualEntries.count != before else { return }
        manualCount = manualEntries.count
        recompute()
        state = .loaded
        LedgerStore.save(manualEntries)
        rebuildHistoryAfterLedgerChange()
    }

    /// Replace a holding outright — set its quantity and cost basis to new
    /// values. Implemented by dropping the asset's manual entries (and paired
    /// cash legs) and recording one balance fact, so editing is clean for the
    /// common single-holding case. A holding built from many transactions is
    /// consolidated into this one.
    func setHolding(assetID: String, quantity: Decimal, unitCostUSD: Decimal) {
        let sym = assetID.uppercased()
        let groups = Set(manualEntries.filter { $0.assetID == sym }.compactMap(\.groupID))
        manualEntries.removeAll { e in
            e.assetID == sym || (e.groupID.map(groups.contains) ?? false)
        }
        if quantity > 0 {
            var d = TransactionDraft()
            d.kind = .balance
            d.asset = sym
            d.quantityText = "\(quantity)"
            d.priceText = "\(unitCostUSD)"
            manualEntries.append(contentsOf: d.makeEntries())
        }
        manualCount = manualEntries.count
        recompute()
        state = .loaded
        LedgerStore.save(manualEntries)
        rebuildHistoryAfterLedgerChange()
    }

    /// Wipe every transaction the user entered (and any loaded sample data),
    /// back to a clean $0 slate.
    func clearAll() {
        manualEntries = []
        sourceEntries = []
        manualCount = 0
        reconstructed = []
        recompute()
        state = .loaded
        LedgerStore.save(manualEntries)
    }

    private var allEntries: [LedgerEntry] {
        (sourceEntries + manualEntries).sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
    }

    private func recompute() {
        let entries = allEntries
        guard !entries.isEmpty else { snapshot = nil; return }
        snapshot = PortfolioEngine(method: method).snapshot(entries: entries, spot: spot)
        recordSnapshot()
    }

    /// Record (or update) today's net-worth snapshot — one honest point per
    /// calendar day, kept current with the latest value seen that day.
    private func recordSnapshot() {
        guard let snap = snapshot else { return }
        let nw = (snap.netWorthUSD as NSDecimalNumber).doubleValue
        let cash = (snap.cashUSD as NSDecimalNumber).doubleValue
        let crypto = (snap.cryptoValueUSD as NSDecimalNumber).doubleValue
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        let point = NetWorthSnapshot(date: today, netWorthUSD: nw, cashUSD: cash, cryptoUSD: crypto)
        if let last = history.last, cal.isDate(last.date, inSameDayAs: today) {
            history[history.count - 1] = point
        } else {
            history.append(point)
        }
        SnapshotStore.save(history)
    }
}

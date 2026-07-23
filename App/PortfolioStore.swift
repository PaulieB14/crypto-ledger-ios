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

    /// Backfill the chart from the ledger × per-coin price history. Runs after
    /// the catalog loads (it needs symbol→id); safe to call again.
    func reconstructHistory(coinIDBySymbol: [String: String]) async {
        guard !coinIDBySymbol.isEmpty else { return }
        reconstructed = await NetWorthReconstruction.series(
            entries: allEntries, coinIDBySymbol: coinIDBySymbol)
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

    /// Development wiring. No network, no keys, no accounts.
    ///
    /// A fixture that fails to load reports why instead of rendering an empty
    /// portfolio — "no data" and "couldn't read the data" look identical on
    /// screen and are very different problems.
    nonisolated static func fixtures() -> PortfolioStore {
        do {
            let bundle = try FixtureBundle.load()
            return PortfolioStore(
                sources: [FixtureSource(entries: bundle.entries)],
                spot: bundle.spot)
        } catch {
            return PortfolioStore(
                sources: [],
                initialError: "Couldn't read fixtures.json — \(error). "
                    + "Check that LedgerCore is linked to this target and that "
                    + "Resources/fixtures.json is in the package's copy rule.")
        }
    }

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
    }

    /// Wipe every transaction the user entered (and any loaded sample data),
    /// back to a clean $0 slate.
    func clearAll() {
        manualEntries = []
        sourceEntries = []
        manualCount = 0
        recompute()
        state = .loaded
        LedgerStore.save(manualEntries)
    }

    /// Load the bundled sample portfolio for a quick look. It lives only in
    /// memory (never persisted), so "Clear all" removes it cleanly.
    func loadSample() {
        guard let bundle = try? FixtureBundle.load() else { return }
        sourceEntries = bundle.entries
        for (asset, price) in bundle.spot where spot[asset] == nil { spot[asset] = price }
        recompute()
        state = .loaded
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

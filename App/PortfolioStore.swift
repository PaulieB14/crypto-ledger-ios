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

    var method: CostBasisMethod = .fifo {
        didSet { recompute() }
    }

    private var entries: [LedgerEntry] = []
    private var spot: [String: Decimal] = [:]
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
        self.spot = spot
        self.initialError = initialError
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
        do {
            entries = try await aggregator.loadAll()
            guard !entries.isEmpty else {
                state = .failed("No entries returned by any source.")
                return
            }
            recompute()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func recompute() {
        guard !entries.isEmpty else { return }
        snapshot = PortfolioEngine(method: method).snapshot(entries: entries, spot: spot)
    }
}

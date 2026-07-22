import Foundation

/// Anything that can produce ledger entries: an exchange connection, a watched
/// address, a CSV import, manual entry.
///
/// Conformers return entries and nothing else. They do not compute balances,
/// do not compute P&L, and do not decide what a transfer means. That keeps
/// every provider replaceable and keeps the accounting in one place.
public protocol PortfolioSource: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Entries at or after `since`. Pass nil for a full backfill.
    /// Callers de-duplicate on `LedgerEntry.dedupeKey`, so returning overlapping
    /// windows is safe and expected.
    func fetchEntries(since: Date?) async throws -> [LedgerEntry]
}

/// Current spot prices, separated from historical prices deliberately: spot is
/// hot and volatile, historical is immutable and cacheable forever.
public protocol PriceSource: Sendable {
    func spotUSD(for assetID: String) async throws -> Decimal?
}

/// Collapses several sources into one entry stream, de-duplicated and ordered.
public struct SourceAggregator: Sendable {
    public let sources: [any PortfolioSource]

    public init(sources: [any PortfolioSource]) {
        self.sources = sources
    }

    public func loadAll(since: Date? = nil) async throws -> [LedgerEntry] {
        var collected: [LedgerEntry] = []
        for source in sources {
            collected.append(contentsOf: try await source.fetchEntries(since: since))
        }
        var seen = Set<String>()
        return collected
            .filter { seen.insert($0.dedupeKey).inserted }
            .sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
    }
}

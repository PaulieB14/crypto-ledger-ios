import Foundation

/// Bundled scenario used for development and for the known-answer tests.
///
/// Nothing here touches the network. Every provider you add later conforms to
/// the same two protocols, so the entire app can be developed, demoed and
/// screenshotted without a single real API key existing anywhere.
public struct FixtureBundle: Sendable {
    public let entries: [LedgerEntry]
    public let spot: [String: Decimal]

    public static func load() throws -> FixtureBundle {
        guard let url = Bundle.module.url(forResource: "fixtures", withExtension: "json") else {
            throw FixtureError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> FixtureBundle {
        struct Payload: Decodable {
            let spot: [String: String]
            let entries: [LedgerEntry]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var prices: [String: Decimal] = [:]
        for (asset, raw) in payload.spot {
            guard let value = Decimal(string: raw) else { throw FixtureError.badDecimal(raw) }
            prices[asset] = value
        }
        return FixtureBundle(entries: payload.entries, spot: prices)
    }

    public enum FixtureError: Error {
        case missingResource
        case badDecimal(String)
    }
}

public struct FixtureSource: PortfolioSource {
    public let id = "fixture"
    public let displayName = "Sample data"
    private let entries: [LedgerEntry]

    public init(entries: [LedgerEntry]) {
        self.entries = entries
    }

    public init() throws {
        self.entries = try FixtureBundle.load().entries
    }

    public func fetchEntries(since: Date?) async throws -> [LedgerEntry] {
        guard let since else { return entries }
        return entries.filter { $0.timestamp >= since }
    }
}

public struct FixturePriceSource: PriceSource {
    private let prices: [String: Decimal]

    public init(prices: [String: Decimal]) {
        self.prices = prices
    }

    public func spotUSD(for assetID: String) async throws -> Decimal? {
        prices[assetID]
    }
}

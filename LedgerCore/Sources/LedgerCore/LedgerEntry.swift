import Foundation

/// What an entry represents. One entry = one asset moving in one account.
///
/// A trade is *several* entries sharing a `groupID` (USD out, BTC in, fee out)
/// rather than one entry with a fee field. This removes the "is the fee already
/// reflected in the quantity?" ambiguity that produces most balance drift.
public enum EntryKind: String, Codable, Sendable, CaseIterable {
    case deposit        // fiat in
    case withdrawal     // fiat out
    case buy            // asset acquired for fiat
    case sell           // asset disposed for fiat
    case swapIn         // asset acquired in a crypto-for-crypto trade
    case swapOut        // asset disposed in a crypto-for-crypto trade
    case transferIn     // asset arriving from another account you control
    case transferOut    // asset leaving for another account you control
    case reward         // staking / interest income
    case airdrop        // received at market value, zero cost
    case fee            // network or exchange fee, paid in this asset

    /// Creates a tax lot.
    public var isAcquisition: Bool {
        switch self {
        case .buy, .swapIn, .reward, .airdrop: true
        default: false
        }
    }

    /// Consumes tax lots.
    public var isDisposal: Bool {
        switch self {
        case .sell, .swapOut: true
        default: false
        }
    }

    public var isTransfer: Bool {
        self == .transferIn || self == .transferOut
    }
}

/// An immutable fact about one asset movement.
///
/// Nothing in this app stores a balance. Balances, positions, cost basis and
/// P&L are all folds over an ordered collection of these. When a provider
/// changes its API or you find a bug in the accounting, you re-derive rather
/// than reconcile.
///
/// Named `LedgerEntry` rather than `Transaction` on purpose: both SwiftUI and
/// StoreKit export a `Transaction` type, and the ambiguity is a constant
/// low-grade tax on every file that imports either.
public struct LedgerEntry: Identifiable, Hashable, Sendable, Codable {

    public let id: String

    /// Which connection produced this (`"coinbase-oauth"`, `"chain-base"`, `"manual"`).
    public let sourceID: String

    /// Provider-side identity, used for idempotent re-import.
    /// Uniqueness is on (`sourceID`, `externalRef`), never on `id`.
    public let externalRef: String

    public let timestamp: Date

    /// Which of the user's accounts holds this asset.
    public let accountID: String

    /// Canonical asset key. For on-chain assets use `"<chain>:<contract>"`;
    /// for exchange assets use the venue symbol. Never bare `"ETH"` across chains.
    public let assetID: String

    /// Signed net change to this asset in this account.
    public let qtyDelta: Decimal

    public let kind: EntryKind

    /// USD price per unit at `timestamp`. Nil means unpriced — the engine will
    /// surface it rather than silently assume zero.
    public let unitPriceUSD: Decimal?

    /// Links the legs of a single trade.
    public var groupID: String?

    /// Set by `TransferMatcher` when this entry is paired with its counterpart.
    public var transferGroupID: String?

    public init(
        id: String = UUID().uuidString,
        sourceID: String,
        externalRef: String,
        timestamp: Date,
        accountID: String,
        assetID: String,
        qtyDelta: Decimal,
        kind: EntryKind,
        unitPriceUSD: Decimal? = nil,
        groupID: String? = nil,
        transferGroupID: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.externalRef = externalRef
        self.timestamp = timestamp
        self.accountID = accountID
        self.assetID = assetID
        self.qtyDelta = qtyDelta
        self.kind = kind
        self.unitPriceUSD = unitPriceUSD
        self.groupID = groupID
        self.transferGroupID = transferGroupID
    }

    public var dedupeKey: String { "\(sourceID)|\(externalRef)" }
}

// MARK: - Codable

// JSONDecoder routes JSON numbers through Double before reaching Decimal, which
// silently corrupts 18-decimal token quantities. Every quantity crosses the wire
// as a string and is parsed with `Decimal(string:)`, which is exact.
extension LedgerEntry {

    private enum CodingKeys: String, CodingKey {
        case id, sourceID, externalRef, timestamp, accountID, assetID
        case qtyDelta, kind, unitPriceUSD, groupID, transferGroupID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        externalRef = try c.decode(String.self, forKey: .externalRef)
        accountID = try c.decode(String.self, forKey: .accountID)
        assetID = try c.decode(String.self, forKey: .assetID)
        kind = try c.decode(EntryKind.self, forKey: .kind)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
        transferGroupID = try c.decodeIfPresent(String.self, forKey: .transferGroupID)

        let stamp = try c.decode(String.self, forKey: .timestamp)
        guard let date = try? LedgerEntry.iso.parse(stamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp, in: c,
                debugDescription: "Expected ISO-8601 with seconds, got \(stamp)")
        }
        timestamp = date

        qtyDelta = try LedgerEntry.decimal(from: c, forKey: .qtyDelta)
        unitPriceUSD = try LedgerEntry.decimalIfPresent(from: c, forKey: .unitPriceUSD)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(externalRef, forKey: .externalRef)
        try c.encode(LedgerEntry.iso.format(timestamp), forKey: .timestamp)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(assetID, forKey: .assetID)
        try c.encode("\(qtyDelta)", forKey: .qtyDelta)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(unitPriceUSD.map { "\($0)" }, forKey: .unitPriceUSD)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encodeIfPresent(transferGroupID, forKey: .transferGroupID)
    }

    /// `ISO8601DateFormatter` is a reference type and not `Sendable`, so a
    /// `static let` of one is a hard error under the Swift 6 language mode.
    /// `ISO8601FormatStyle` is a Sendable value type and parses identically.
    static let iso = Date.ISO8601FormatStyle(timeZone: .gmt)

    private static func decimal(
        from c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Decimal {
        let raw = try c.decode(String.self, forKey: key)
        guard let value = Decimal(string: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c, debugDescription: "Not a decimal: \(raw)")
        }
        return value
    }

    private static func decimalIfPresent(
        from c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Decimal? {
        guard let raw = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let value = Decimal(string: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c, debugDescription: "Not a decimal: \(raw)")
        }
        return value
    }
}

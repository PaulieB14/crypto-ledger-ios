import Foundation

/// The on-device ledger file. `LedgerStore` writes this exact encoding to
/// `entries.json`; export hands the user those bytes and import reads them
/// back. Quantities stay strings, same as `LedgerEntry`'s Codable, so an
/// 18-decimal token amount survives the round trip.
///
/// This is not the CSV trade importer. A CSV is a list of buys; this is the
/// ledger itself.
public enum LedgerArchive {

    public static func encode(_ entries: [LedgerEntry]) throws -> Data {
        try JSONEncoder().encode(entries)
    }

    public static func decode(_ data: Data) throws -> [LedgerEntry] {
        try JSONDecoder().decode([LedgerEntry].self, from: data)
    }
}

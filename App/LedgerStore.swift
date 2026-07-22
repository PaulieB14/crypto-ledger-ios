import Foundation
import LedgerCore

/// Local, dependency-free persistence for user-entered ledger entries — a JSON
/// file in Application Support. Lives in the app layer so `LedgerCore` stays
/// storage-agnostic. `LedgerEntry`'s exact string-based Codable (the same one
/// that loads fixtures) round-trips 18-decimal quantities without loss.
///
/// For a heavier store the repo also ships a GRDB-backed `LedgerDatabase`;
/// swapping to it is a drop-in behind this same load/save shape.
enum LedgerStore {

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("CryptoLedger", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("entries.json")
    }

    static func load() -> [LedgerEntry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LedgerEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [LedgerEntry]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

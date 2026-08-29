import Foundation

/// One recorded day of net worth. Snapshots are the honest, authoritative
/// history — captured going forward from install day, one point per calendar
/// day (updated to the latest value seen that day).
struct NetWorthSnapshot: Codable, Hashable {
    let date: Date          // start of the calendar day
    let netWorthUSD: Double
    let cashUSD: Double
    let cryptoUSD: Double
}

/// Local JSON persistence for the net-worth history, alongside `LedgerStore`.
enum SnapshotStore {
    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("CryptoLedger", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("networth_history.json")
    }

    static func load() -> [NetWorthSnapshot] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([NetWorthSnapshot].self, from: data)) ?? []
    }

    static func save(_ snaps: [NetWorthSnapshot]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snaps) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Delete the recorded history outright, for "Clear all data". Removes the
    /// file rather than writing an empty array, so nothing of the old series is
    /// left on disk to be recovered.
    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

import Foundation
import GRDB
import LedgerCore

// Persistence lives here and nowhere else. `LedgerCore` has no GRDB dependency,
// so every accounting decision is testable without a database and the storage
// layer can be replaced without touching the math.
//
// Table is `ledger_entry`, not `transaction`: SQLite treats TRANSACTION as a
// keyword and you would be quoting it forever.

extension LedgerEntry: FetchableRecord, PersistableRecord {

    public static let databaseTableName = "ledger_entry"

    public enum Columns {
        public static let id = Column("id")
        public static let sourceID = Column("source_id")
        public static let externalRef = Column("external_ref")
        public static let timestamp = Column("timestamp")
        public static let accountID = Column("account_id")
        public static let assetID = Column("asset_id")
        public static let qtyDelta = Column("qty_delta")
        public static let kind = Column("kind")
        public static let unitPriceUSD = Column("unit_price_usd")
        public static let groupID = Column("group_id")
        public static let transferGroupID = Column("transfer_group_id")
    }

    public init(row: Row) {
        self.init(
            id: row["id"],
            sourceID: row["source_id"],
            externalRef: row["external_ref"],
            timestamp: Date(timeIntervalSince1970: row["timestamp"]),
            accountID: row["account_id"],
            assetID: row["asset_id"],
            // Quantities are stored as TEXT. SQLite's REAL is a double and would
            // quietly round 18-decimal token amounts.
            qtyDelta: Decimal(string: row["qty_delta"]) ?? 0,
            kind: EntryKind(rawValue: row["kind"]) ?? .deposit,
            unitPriceUSD: (row["unit_price_usd"] as String?).flatMap(Decimal.init(string:)),
            groupID: row["group_id"],
            transferGroupID: row["transfer_group_id"]
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["source_id"] = sourceID
        container["external_ref"] = externalRef
        container["timestamp"] = timestamp.timeIntervalSince1970
        container["account_id"] = accountID
        container["asset_id"] = assetID
        container["qty_delta"] = "\(qtyDelta)"
        container["kind"] = kind.rawValue
        container["unit_price_usd"] = unitPriceUSD.map { "\($0)" }
        container["group_id"] = groupID
        container["transfer_group_id"] = transferGroupID
    }
}

public struct LedgerDatabase: Sendable {

    public let writer: any DatabaseWriter

    public init(path: String) throws {
        var config = Configuration()
        // The ledger is financial data. It is encrypted at rest by iOS file
        // protection; keys and secrets never come near this database.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        writer = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(writer)
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_ledger") { db in
            try db.create(table: "ledger_entry") { t in
                t.column("id", .text).primaryKey()
                t.column("source_id", .text).notNull()
                t.column("external_ref", .text).notNull()
                t.column("timestamp", .double).notNull()
                t.column("account_id", .text).notNull()
                t.column("asset_id", .text).notNull()
                t.column("qty_delta", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("unit_price_usd", .text)
                t.column("group_id", .text)
                t.column("transfer_group_id", .text)
            }
            // Idempotent re-import depends on this. Without it, every backfill
            // duplicates history and every balance doubles.
            try db.create(
                index: "idx_ledger_dedupe",
                on: "ledger_entry",
                columns: ["source_id", "external_ref"],
                unique: true)
            try db.create(
                index: "idx_ledger_asset_time",
                on: "ledger_entry",
                columns: ["asset_id", "timestamp"])
        }

        return migrator
    }

    /// Insert-or-ignore on the dedupe key, so re-importing an overlapping
    /// window is always safe.
    public func upsert(_ entries: [LedgerEntry]) throws {
        try writer.write { db in
            for entry in entries {
                try entry.insert(db, onConflict: .ignore)
            }
        }
    }

    public func allEntries() throws -> [LedgerEntry] {
        try writer.read { db in
            try LedgerEntry
                .order(Columns.timestamp.asc, Columns.id.asc)
                .fetchAll(db)
        }
    }
}

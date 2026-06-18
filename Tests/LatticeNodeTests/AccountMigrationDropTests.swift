import XCTest
@testable import LatticeNode

/// (DECISION LOCKED Round 10): the per-boot
/// `DELETE FROM state WHERE path LIKE 'account:%'` migration is REMOVED.
///
/// It cleaned up the legacy duplicated-state design that no longer ships
/// post-flag-day and ran a full-table scan on EVERY `StateStore.init`. A
/// schema-version gate was ruled out (it conflicts with the no-migration-
/// versioning lock), so the delete is dropped outright.
///
/// RED on main: a fresh `StateStore` over an existing `state.db` runs the
/// DELETE in `createTables()` and wipes any `account:`-prefixed row. GREEN:
/// the row survives a re-init.
final class AccountMigrationDropTests: XCTestCase {

    func test_boot_doesNotDeleteAccountRows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // First init creates the schema + state.db.
        _ = try StateStore(storagePath: dir, chain: "Nexus")

        // Seed an `account:`-prefixed row directly into the same state.db via a
        // raw connection (StateStore exposes no setter for arbitrary paths).
        let dbPath = dir.appendingPathComponent("Nexus").appendingPathComponent("state.db").path
        let raw = try SQLiteDatabase(path: dbPath)
        try raw.execute(
            "INSERT OR REPLACE INTO state (path, value, height) VALUES ('account:abc', ?1, 1)",
            params: [.blob(Data([0x01, 0x02]))]
        )
        let before = try raw.query("SELECT COUNT(*) AS c FROM state WHERE path LIKE 'account:%'")
        XCTAssertEqual(before.first?["c"]?.intValue, 1, "precondition: the account: row is present")

        // Re-init over the SAME path → runs createTables() again. On main this
        // executes the DELETE and wipes the row; after the fix it must survive.
        _ = try StateStore(storagePath: dir, chain: "Nexus")

        let after = try raw.query("SELECT COUNT(*) AS c FROM state WHERE path LIKE 'account:%'")
        XCTAssertEqual(after.first?["c"]?.intValue, 1,
                       "the account: boot-migration DELETE must no longer run on init (Round-10 decision)")
    }
}

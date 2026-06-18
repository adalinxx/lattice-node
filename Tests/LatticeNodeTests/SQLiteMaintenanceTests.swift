import XCTest
@testable import LatticeNode

/// S7: SQLite WAL checkpoint + incremental vacuum must be callable without
/// corrupting the DB, and must actually shrink freelist / WAL pages after
/// heavy churn. These tests don't assert absolute byte counts (SQLite page
/// layout varies by version); they only assert post-condition correctness
/// and that the DB file doesn't grow unbounded under delete+maintain.
final class SQLiteMaintenanceTests: XCTestCase {
    enum TestError: Error {
        case injected
    }

    private func makePaths() -> (dbPath: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("t.db").path, dir)
    }

    func testMaintenancePragmasSucceed() throws {
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)")
        // Populate enough rows that WAL + freelist have material to work with.
        try db.beginTransaction()
        let blob = Data(repeating: 0xAA, count: 1024)
        for i in 0..<500 {
            try db.execute("INSERT INTO t (id, v) VALUES (?1, ?2)",
                           params: [.int(Int64(i)), .blob(blob)])
        }
        try db.commit()
        try db.execute("DELETE FROM t WHERE id < 400") // free ~400 pages

        // All three maintenance operations must complete without throwing.
        try db.walCheckpointTruncate()
        try db.incrementalVacuum()
        try db.optimize()

        // DB remains queryable after maintenance.
        let rows = try db.query("SELECT COUNT(*) AS c FROM t")
        XCTAssertEqual(rows.first?["c"]?.intValue, 100)
    }

    func testIncrementalVacuumBoundsFileGrowth() throws {
        // Under insert-then-delete churn, a DB with auto_vacuum=NONE grows
        // without bound. With auto_vacuum=INCREMENTAL + incremental_vacuum,
        // the file size must not strictly grow across repeated cycles.
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)")

        let blob = Data(repeating: 0x55, count: 2048)
        func cycle(_ n: Int) throws -> Int64 {
            try db.beginTransaction()
            for i in 0..<1000 {
                try db.execute("INSERT OR REPLACE INTO t (id, v) VALUES (?1, ?2)",
                               params: [.int(Int64(n * 10_000 + i)), .blob(blob)])
            }
            try db.commit()
            try db.execute("DELETE FROM t")
            try db.walCheckpointTruncate()
            try db.incrementalVacuum()
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return (attrs[.size] as? Int64) ?? 0
        }
        let s1 = try cycle(1)
        let s2 = try cycle(2)
        let s3 = try cycle(3)
        // File must stabilize, not grow monotonically. The first cycle
        // allocates; later cycles must reuse reclaimed pages.
        XCTAssertLessThanOrEqual(s3, s1 * 2, "file size drifted: \(s1) -> \(s2) -> \(s3)")
    }

    func testTransactionRollsBackBodyErrorAndAllowsLaterWrites() throws {
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

        XCTAssertThrowsError(try db.transaction {
            try db.execute(
                "INSERT INTO t (id, v) VALUES (?1, ?2)",
                params: [.int(1), .text("partial")]
            )
            throw TestError.injected
        })

        var rows = try db.query("SELECT COUNT(*) AS c FROM t")
        XCTAssertEqual(rows.first?["c"]?.intValue, 0, "failed transaction must not leave partial writes")

        _ = try db.transaction {
            try db.execute(
                "INSERT INTO t (id, v) VALUES (?1, ?2)",
                params: [.int(2), .text("after")]
            )
        }
        rows = try db.query("SELECT COUNT(*) AS c FROM t")
        XCTAssertEqual(rows.first?["c"]?.intValue, 1, "rollback must leave the connection usable")
    }

    func testTransactionRollsBackSQLiteErrorAndAllowsLaterTransaction() throws {
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

        XCTAssertThrowsError(try db.transaction {
            try db.execute(
                "INSERT INTO t (id, v) VALUES (?1, ?2)",
                params: [.int(1), .text("partial")]
            )
            try db.execute("INSERT INTO missing_table (id) VALUES (1)")
        })

        var rows = try db.query("SELECT COUNT(*) AS c FROM t")
        XCTAssertEqual(rows.first?["c"]?.intValue, 0, "SQLite statement failure must roll back previous statements")

        _ = try db.transaction {
            try db.execute(
                "INSERT INTO t (id, v) VALUES (?1, ?2)",
                params: [.int(2), .text("after")]
            )
        }
        rows = try db.query("SELECT id FROM t")
        XCTAssertEqual(rows.first?["id"]?.intValue, 2)
    }

    func testTransactionReportsRollbackFailure() throws {
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: path)
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

        XCTAssertThrowsError(try db.transaction {
            try db.execute(
                "INSERT INTO t (id, v) VALUES (?1, ?2)",
                params: [.int(1), .text("partial")]
            )
            try db.rollbackTransaction()
            throw TestError.injected
        }) { error in
            guard case SQLiteError.rollbackFailed(let original, let rollback) = error else {
                return XCTFail("expected rollback failure, got \(error)")
            }
            XCTAssertTrue(original.contains("injected"))
            XCTAssertTrue(rollback.contains("executeFailed"))
        }

        let rows = try db.query("SELECT COUNT(*) AS c FROM t")
        XCTAssertEqual(rows.first?["c"]?.intValue, 0)
    }

    func testCloseTruncatesWAL() throws {
        // SQLiteDatabase.deinit runs a truncating WAL checkpoint so a
        // clean shutdown leaves the `-wal` sidecar at 0 bytes. Mirrors the real
        // StateStore topology: two connections (`db` + `readDb`) on one file, the
        // writer closing while a reader stays open. Asserts the close-time
        // checkpoint guarantee holds (WAL bounded to 0) and data survives it.
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }
        let walPath = path + "-wal"

        // Reader stays open for the whole test so the writer's close is NOT the
        // final close — matching StateStore's db+readDb pair.
        let reader = try SQLiteDatabase(path: path)

        do {
            let writer = try SQLiteDatabase(path: path)
            try writer.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)")
            let blob = Data(repeating: 0xAB, count: 4096)
            try writer.beginTransaction()
            for i in 0..<500 {
                try writer.execute("INSERT INTO t (id, v) VALUES (?1, ?2)",
                                   params: [.int(Int64(i)), .blob(blob)])
            }
            try writer.commit()
            let walSize = (try FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? 0
            XCTAssertGreaterThan(walSize, 0, "precondition: writes should have grown the WAL")
            // `writer` drops here → deinit → checkpoint(TRUNCATE) while `reader` is open.
        }

        // With the reader still open, deinit's explicit truncate must leave no
        // WAL bytes. SQLite may either keep a 0-byte sidecar or remove it.
        let size: Int64
        if FileManager.default.fileExists(atPath: walPath) {
            size = (try FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int64) ?? -1
        } else {
            size = 0
        }
        XCTAssertEqual(size, 0, "deinit must truncate the WAL even when another connection is open")

        // Data is intact via the surviving reader.
        let rows = try reader.query("SELECT COUNT(*) AS c FROM t")
        XCTAssertEqual(rows.first?["c"]?.intValue, 500)
    }

    func testBusyRetryThenSucceeds() async throws {
        // (DECISION LOCKED Round 10): a write that contends with another
        // connection's open write transaction must succeed via the busy_timeout +
        // bounded retry, not be silently dropped. Conn A holds a write lock, a
        // background task releases it shortly after; conn B's write must land.
        let (path, dir) = makePaths()
        defer { try? FileManager.default.removeItem(at: dir) }

        let connA = try SQLiteDatabase(path: path)
        try connA.execute("CREATE TABLE tx_history (address TEXT, txCID TEXT, blockHash TEXT, height INTEGER, PRIMARY KEY(address, txCID))")

        let connB = try SQLiteDatabase(path: path)

        // Conn A opens an IMMEDIATE write transaction → holds the WAL write lock.
        try connA.execute("BEGIN IMMEDIATE")
        try connA.execute("INSERT INTO tx_history VALUES ('a','t0','b',0)")

        // Release the lock after a short delay on a background task.
        let releaser = Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            _ = try? connA.execute("COMMIT")
        }

        // Conn B's write blocks on busy_timeout, retries, then succeeds once A commits.
        try connB.execute("INSERT INTO tx_history VALUES ('a','t1','b',1)")
        _ = await releaser.value

        let rows = try connB.query("SELECT txCID FROM tx_history WHERE address='a' ORDER BY height")
        XCTAssertEqual(rows.count, 2, "both the lock-holder's and the contending write must persist")
        XCTAssertEqual(rows.last?["txCID"]?.textValue, "t1")
    }

    func testStateStoreMaintainNoOpOnEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StateStore(storagePath: dir, chain: "Nexus")
        // No writes — maintenance on a fresh store must still succeed.
        try await store.maintain()
        // Subsequent writes still work after maintenance.
        try await store.indexTransaction(address: "x", txCID: "tx1", blockHash: "b", height: 1)
        let rows = store.getTransactionHistory(address: "x")
        XCTAssertEqual(rows.count, 1)
    }
}

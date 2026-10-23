import CSQLite
import Foundation

/// Minimal read-mostly SQLite wrapper (no third-party dependency).
public final class SQLiteDB: @unchecked Sendable {
    public enum DBError: Error { case open(String), prepare(String), step(String) }
    let handle: OpaquePointer

    public init(path: String, readOnly: Bool = true) throws {
        var h: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            throw DBError.open(path)
        }
        handle = h
    }

    deinit { sqlite3_close(handle) }

    public enum Value { case int(Int64), text(String), blob(Data), null }

    public func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DBError.step(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Runs `sql` with text/int bindings and calls `row` for each result row.
    public func query(_ sql: String, _ binds: [Any] = [], row: (Row) throws -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            switch b {
            case let s as String: sqlite3_bind_text(st, Int32(i + 1), s, -1, transient)
            case let n as Int: sqlite3_bind_int64(st, Int32(i + 1), Int64(n))
            case let n as Int64: sqlite3_bind_int64(st, Int32(i + 1), n)
            case let b as Bool: sqlite3_bind_int64(st, Int32(i + 1), b ? 1 : 0)
            case let x as Double: sqlite3_bind_double(st, Int32(i + 1), x)
            case let d as Data: _ = d.withUnsafeBytes { sqlite3_bind_blob(st, Int32(i + 1), $0.baseAddress, Int32(d.count), transient) }
            default: sqlite3_bind_null(st, Int32(i + 1))
            }
        }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw DBError.step(String(cString: sqlite3_errmsg(handle))) }
            try row(Row(st: st))
        }
    }

    /// Rowid of the last INSERT on this connection.
    public var lastInsertRowID: Int { Int(sqlite3_last_insert_rowid(handle)) }

    public struct Row {
        let st: OpaquePointer
        public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(st, i) }
        public func text(_ i: Int32) -> String {
            guard let p = sqlite3_column_text(st, i) else { return "" }
            return String(cString: p)
        }
        /// Little-endian float32 blob -> [Float] (same layout the brain writes with struct.pack("f")).
        public func floats(_ i: Int32) -> [Float] {
            let n = Int(sqlite3_column_bytes(st, i)) / MemoryLayout<Float>.size
            guard n > 0, let p = sqlite3_column_blob(st, i) else { return [] }
            return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: n))
        }
    }
}

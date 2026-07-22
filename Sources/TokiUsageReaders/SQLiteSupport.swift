#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteBind {
    case int64(Int64)
    case text(String)
}

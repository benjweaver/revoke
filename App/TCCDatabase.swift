import Foundation
import Security
import SQLite3

/// Reads the system privacy database (TCC), where macOS keeps Device Control, Screen
/// Recording, Input Monitoring and Full Disk Access. Opening it needs Full Disk Access.
/// Nothing outside Apple can write to it, not even root, because System Integrity
/// Protection guards it.
///
/// The rest, like Automation, the camera and microphone, and System Audio Recording
/// Only, lives in each user's database, which macOS 27 keeps where no app can read it.
/// tccd hands that list only to Apple's own software, so Revoke can reset those but
/// can't show them.
enum TCCDatabase {
    private static let path = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// Every entry for the panel's columns, or nil when the database can't be read.
    static func read() -> [(Client, Pane, Entry)]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }

        let services = Pane.allCases.compactMap(\.tccService).map { "'\($0)'" }.joined(separator: ", ")
        let sql = """
            SELECT service, client, client_type, auth_value, last_modified, csreq FROM access
            WHERE service IN (\(services))
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }

        var rows: [(Client, Pane, Entry)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let service = text(statement, 0), let name = text(statement, 1),
                      let pane = Pane.allCases.first(where: { $0.tccService == service }) else { continue }
                // client_type 0 is a bundle ID and 1 an executable path.
                let client: Client = sqlite3_column_int(statement, 2) == 0 ? .bundle(name) : .path(name)
                // auth_value 2 is allowed and 3 limited. 0 is a switched-off entry.
                let value = sqlite3_column_int(statement, 3)
                let since = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4)))
                rows.append((client, pane, Entry(access: value == 2 || value == 3 ? .allowed : .denied,
                                                 since: since, isAppleSystem: isAppleSystem(statement, 5))))
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    /// Whether the entry's code requirement pins it to code Apple ships with macOS.
    /// That's "anchor apple" on its own; apps from other developers carry "anchor
    /// apple generic" and their certificate, or an ad-hoc signature's hash. Unlike a
    /// "com.apple." bundle ID, which any app can claim, no one else can meet it.
    private static func isAppleSystem(_ statement: OpaquePointer?, _ column: Int32) -> Bool {
        guard let bytes = sqlite3_column_blob(statement, column) else { return false }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        var requirement: SecRequirement?
        var text: CFString?
        guard SecRequirementCreateWithData(data as CFData, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else { return false }
        return (text as String).range(of: "anchor apple(?! generic)", options: .regularExpression) != nil
    }
}

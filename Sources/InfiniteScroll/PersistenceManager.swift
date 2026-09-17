import Foundation

struct AppState: Codable {
    let panels: [PanelState]
    let nextIndex: Int
    let fontSize: CGFloat?
    let fontName: String?
    let rowHeight: CGFloat?
    let commandScrollSpeed: CGFloat?
    let scrollbackLimit: Int?
}

enum PersistenceManager {
    private static let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".infinite-scroll")
    private static let fileURL = directoryURL.appendingPathComponent("state.json")

    static func save(_ state: AppState) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("PersistenceManager: failed to save — \(error)")
        }
    }

    static func load() -> AppState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(AppState.self, from: data)
        } catch {
            // Never let a decode failure look like "no workspace yet": that
            // made the next save overwrite the user's layout with a fresh one.
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            print("PersistenceManager: failed to load, moved aside to \(backup.lastPathComponent) — \(error)")
            return nil
        }
    }
}

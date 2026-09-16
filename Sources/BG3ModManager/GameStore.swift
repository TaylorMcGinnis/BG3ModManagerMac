import Foundation
import SQLite3

/// Which storefront's build of BG3 is installed.
///
/// Steam and GOG ship the same game version as different binaries — both report
/// `CFBundleShortVersionString = 4.1.1.7398727`, and every address differs.
/// BG3SE-macOS bakes those addresses in at compile time, so there is one dylib
/// per store and the wrong one disables itself on detecting the mismatch.
enum GameStore: String, Equatable {
    case steam
    case gog

    /// Larian suffixes the game executable per store: GOG's `CFBundleExecutable`
    /// is a ~200KB arch-selector stub with the 501MB game beside it as
    /// `<CFBundleExecutable> GOG`. Steam's `CFBundleExecutable` is the game.
    static let execSuffixes: [(suffix: String, store: GameStore)] = [
        (" GOG", .gog), (" Steam", .steam),
    ]

    /// Identify the store from an installed game bundle. Keyed on the
    /// executable layout, not the path — a GOG bundle symlinked into
    /// `steamapps/common` is still GOG.
    static func detect(in gameApp: URL) -> GameStore {
        guard let name = bundleExecutableName(of: gameApp) else { return .steam }
        let macos = gameApp.appendingPathComponent("Contents/MacOS")
        for (suffix, store) in execSuffixes {
            let candidate = macos.appendingPathComponent(name + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) { return store }
        }
        return .steam
    }

    /// The game binary inside `gameApp`, which is not necessarily its
    /// `CFBundleExecutable`. Injecting into the GOG stub misses the game.
    static func executable(in gameApp: URL) -> URL? {
        guard let name = bundleExecutableName(of: gameApp) else { return nil }
        let macos = gameApp.appendingPathComponent("Contents/MacOS")
        for (suffix, _) in execSuffixes {
            let candidate = macos.appendingPathComponent(name + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let plain = macos.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: plain.path) ? plain : nil
    }

    private static func bundleExecutableName(of gameApp: URL) -> String? {
        let plist = gameApp.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
           let name = info["CFBundleExecutable"] as? String, !name.isEmpty {
            return name
        }
        // Game not installed. The bundle stem matches in every BG3 build so far.
        return gameApp.deletingPathExtension().lastPathComponent
    }

    /// The BG3SE-macOS launcher script this store needs.
    var launcherScriptName: String {
        switch self {
        case .steam: return "scripts/bg3w.sh"
        case .gog:   return "scripts/bg3g.sh"
        }
    }

    /// Where a build for this store lands in a BG3SE-macOS checkout.
    var buildDirectory: String {
        switch self {
        case .steam: return "build"
        case .gog:   return "build-gog"
        }
    }

    /// Store labels that may appear in a release asset filename, for telling a
    /// labelled asset from a legacy unlabelled one.
    static let allLabels: [String] = [GameStore.steam.rawValue, GameStore.gog.rawValue]

    var displayName: String {
        switch self {
        case .steam: return "Steam"
        case .gog:   return "GOG"
        }
    }
}

// MARK: - GOG Galaxy launch wiring

/// Read what GOG Galaxy is set to launch for a game.
///
/// Galaxy has no launch-options field and cannot set an environment variable, so
/// `DYLD_INSERT_LIBRARIES` has no hook there. It can launch a different
/// executable — its "Custom executables/arguments" feature — stored in Galaxy's
/// own SQLite database:
///
///   PlayTasks(id, gameReleaseKey)                  — one row per game
///   PlayTaskLaunchParameters(playTaskId, executablePath, commandLineArgs, label)
///   ProductSettings(gameReleaseKey, customLaunchParameters, …)
///
/// READ ONLY, deliberately. Writing those rows was tried and does not hold:
/// Galaxy owns ProductSettings and reverts `customLaunchParameters` on its next
/// start while keeping the new `executablePath`. That leaves the game pointing
/// at a launcher with the feature switched off, and Play does nothing. Galaxy's
/// own UI sets both halves consistently, so this reads the state to report
/// whether setup is done, and the app tells the user what to click.
enum GalaxyLaunchOptions {

    static let databaseURL = URL(fileURLWithPath:
        "/Users/Shared/GOG.com/Galaxy/Storage/galaxy-2.0.db")

    enum GalaxyError: LocalizedError {
        case noDatabase
        case schemaUnexpected(String)

        var errorDescription: String? {
            switch self {
            case .noDatabase:
                return "Couldn't find GOG Galaxy's database. Is Galaxy installed?"
            case .schemaUnexpected(let detail):
                return "GOG Galaxy's database isn't in the expected format (\(detail))."
            }
        }
    }

    /// Galaxy's release key for an installed game, e.g. `gog_1456460669`, from
    /// the `goggame-<id>.info` GOG drops in the bundle's Resources.
    static func releaseKey(for gameApp: URL) -> String? {
        let resources = gameApp.appendingPathComponent("Contents/Resources")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: resources, includingPropertiesForKeys: nil) else { return nil }
        guard let info = entries.first(where: {
            $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info"
        }) else { return nil }

        if let data = try? Data(contentsOf: info),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let gameId = json["gameId"] as? String {
            return "gog_\(gameId)"
        }
        // Fall back to the filename: goggame-1456460669.info
        let id = info.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "goggame-", with: "")
        return id.isEmpty ? nil : "gog_\(id)"
    }

    /// What Galaxy currently launches for this game, if anything.
    static func currentExecutable(for gameApp: URL) -> String? {
        guard let key = releaseKey(for: gameApp), let db = try? open() else { return nil }
        defer { sqlite3_close(db) }
        return try? currentExecutable(db: db, releaseKey: key)
    }

    /// True when Galaxy is already launching through the BG3SE launcher.
    static func isWired(gameApp: URL) -> Bool {
        currentExecutable(for: gameApp)?.hasSuffix("bg3g.sh") ?? false
    }

    /// The steps to set this up in Galaxy, with the launcher path filled in.
    ///
    /// Galaxy's own UI is the only reliable way to set this: it writes the
    /// executable and the enabling flag together, which an external write
    /// cannot do durably.
    static func setupSteps(launcher: URL) -> [String] {
        [
            "Quit Baldur's Gate 3 if it is running.",
            "In GOG Galaxy, select Baldur's Gate 3.",
            "Open Manage installation → Configure (the ⚙ / … button).",
            "Tick “Custom executables/arguments”, then click Duplicate.",
            "Set the executable to:\n\(launcher.path)",
            "Save, then launch the game from Galaxy as usual.",
        ]
    }

    // MARK: Database plumbing

    /// Opened READONLY, so this can never disturb a running Galaxy.
    private static func open() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw GalaxyError.noDatabase
        }
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    private static func currentExecutable(db: OpaquePointer, releaseKey: String) throws -> String? {
        var statement: OpaquePointer?
        let sql = """
            SELECT p.executablePath FROM PlayTaskLaunchParameters p
            JOIN PlayTasks t ON t.id = p.playTaskId
            WHERE t.gameReleaseKey = ? LIMIT 1
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GalaxyError.schemaUnexpected("PlayTaskLaunchParameters isn't shaped as expected")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, releaseKey, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}

/// Tells SQLite the bound string does not outlive the call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

import Foundation

/// Script Extender support for the **native macOS** build, via BG3SE-macOS.
///
/// This is a different mechanism from the Windows SE the app installs into a CrossOver bottle. There
/// is no DLL and nothing is copied into the game folder: BG3SE-macOS builds `libbg3se.dylib` from
/// source and loads it by wrapping the game's launch command. Nothing to install into the Mods
/// folder, and nothing this app can copy into place — so its job here is to find the checkout,
/// report exactly which of the three steps (cloned / built / wired up) is done, and hand over the
/// command to finish it.
///
/// The last two steps depend on the store: Steam and GOG need different builds (`-DBG3_STORE`) and
/// different launchers (`bg3w.sh` via Steam's launch options, `bg3g.sh` via Galaxy's custom
/// executable).
///
/// Project: https://github.com/mageweaver/bg3se-macos
enum ScriptExtenderMac {

    static let repository = URL(string: "https://github.com/mageweaver/bg3se-macos")!

    /// A BG3SE-macOS checkout and how far along its setup is.
    struct Installation: Equatable {
        var root: URL
        /// Which store's build this targets. Steam unless a GOG bundle was found.
        var store: GameStore = .steam
        /// The launcher for this store: `scripts/bg3w.sh` or `scripts/bg3g.sh`.
        var launchScript: URL?
        /// `build/lib/libbg3se.dylib` (or `build-gog/…`), present once built for
        /// this store. A Steam build does not count as a GOG one — the extender
        /// disables itself on mismatched addresses.
        var dylib: URL?
        var dylibBuiltAt: Date?
        var dylibBytes: Int64 = 0
        var isUniversal = false
        /// True when the store's launcher is wired up: Steam's launch options,
        /// or Galaxy's custom executable.
        var isWired = false

        var isBuilt: Bool { dylib != nil }
        var isReady: Bool { isBuilt && launchScript != nil && isWired }

        /// What the user pastes into Steam → BG3 → Properties → Launch Options.
        /// Steam only — Galaxy takes an executable, not a command line. See
        /// `GalaxyLaunchOptions`.
        var launchOptions: String? {
            guard store == .steam else { return nil }
            return launchScript.map { "\($0.path) %command%" }
        }

        var stage: Stage {
            if !isBuilt { return .notBuilt }
            if !isWired { return .notWired }
            return .ready
        }

        enum Stage { case notBuilt, notWired, ready }
    }

    // MARK: Finding a checkout

    /// Places a checkout commonly ends up, tried in order. A path set in Settings always wins.
    private static var searchRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["bg3se-macos", "src/bg3se-macos", "src/BG3SE/macos-port", "Developer/bg3se-macos",
                "Documents/bg3se-macos", "code/bg3se-macos", "projects/bg3se-macos",
                "Claude/Projects/bg3se-macos"]
            .map { home.appendingPathComponent($0) }
    }

    /// Locate a usable checkout: the configured path first, then the usual spots.
    ///
    /// `gameApp` decides which store's build and launcher to look for; nil
    /// assumes Steam.
    static func discover(configuredPath: String, gameApp: URL? = nil) -> Installation? {
        let store = gameApp.map(GameStore.detect(in:)) ?? .steam
        if !configuredPath.isEmpty,
           let found = inspect(URL(fileURLWithPath: configuredPath), store: store, gameApp: gameApp) {
            return found
        }
        for root in searchRoots {
            if let found = inspect(root, store: store, gameApp: gameApp) { return found }
        }
        return nil
    }

    /// Read the state of a folder claimed to be a BG3SE-macOS checkout. Returns nil if it plainly
    /// isn't one — the launcher script and CMakeLists together are a good enough signature.
    static func inspect(_ root: URL, store: GameStore = .steam,
                        gameApp: URL? = nil) -> Installation? {
        let fm = FileManager.default
        // bg3w.sh is the signature either way: every checkout has it, while
        // bg3g.sh only exists in ones new enough to support GOG.
        let signature = root.appendingPathComponent("scripts/bg3w.sh")
        let cmake = root.appendingPathComponent("CMakeLists.txt")
        guard fm.fileExists(atPath: signature.path) || fm.fileExists(atPath: cmake.path) else {
            return nil
        }

        var install = Installation(root: root, store: store)

        let script = root.appendingPathComponent(store.launcherScriptName)
        if fm.fileExists(atPath: script.path) { install.launchScript = script }

        let dylib = root.appendingPathComponent("\(store.buildDirectory)/lib/libbg3se.dylib")
        if fm.fileExists(atPath: dylib.path) {
            install.dylib = dylib
            let values = try? dylib.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            install.dylibBuiltAt = values?.contentModificationDate
            install.dylibBytes = Int64(values?.fileSize ?? 0)
            install.isUniversal = isUniversalBinary(dylib)
        }

        switch store {
        case .steam:
            install.isWired = steamLaunchOptionsReferenceLauncher()
        case .gog:
            install.isWired = gameApp.map(GalaxyLaunchOptions.isWired(gameApp:)) ?? false
        }
        return install
    }

    // MARK: Steam wiring

    /// Whether any Steam account's stored launch options mention the BG3SE launcher.
    ///
    /// Steam keeps launch options in `localconfig.vdf`. Rather than parse VDF — a format with no
    /// stable schema across Steam versions — this looks for the launcher's filename, which appears
    /// nowhere else. It answers "did you paste it in", which is the step people forget.
    static func steamLaunchOptionsReferenceLauncher() -> Bool {
        for config in steamLocalConfigs() {
            if let text = try? String(contentsOf: config, encoding: .utf8), text.contains("bg3w.sh") {
                return true
            }
        }
        return false
    }

    private static func steamLocalConfigs() -> [URL] {
        let fm = FileManager.default
        let userdata = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/userdata")
        guard let accounts = try? fm.contentsOfDirectory(at: userdata,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return [] }
        return accounts.map { $0.appendingPathComponent("config/localconfig.vdf") }
                       .filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: Build guidance

    /// The commands that produce the dylib, ready to paste into Terminal.
    ///
    /// -DBG3_STORE picks the compile-time address tables, and is not optional
    /// for GOG: a Steam-built dylib disables itself on a GOG install.
    static func buildCommands(for root: URL, store: GameStore = .steam) -> String {
        """
        cd \(root.path)
        git submodule update --init --recursive
        cmake -B \(store.buildDirectory) -DBG3_STORE=\(store.rawValue)
        cmake --build \(store.buildDirectory)
        """
    }

    /// Fat-header check, so the panel can say whether the build covers this Mac's architecture
    /// without shelling out to `file`.
    private static func isUniversalBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        // FAT_MAGIC / FAT_CIGAM, in either byte order.
        let bytes = [UInt8](magic)
        return bytes == [0xca, 0xfe, 0xba, 0xbe] || bytes == [0xbe, 0xba, 0xfe, 0xca]
    }
}

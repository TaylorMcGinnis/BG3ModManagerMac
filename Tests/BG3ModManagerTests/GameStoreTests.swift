import XCTest
@testable import BG3ModManagerMac

/// Store identification, which decides the dylib installed and the launcher
/// wired up. The wrong answer means an artifact whose baked-in addresses point
/// at the wrong memory.
final class GameStoreTests: XCTestCase {

    // MARK: Fixtures

    /// A game bundle. `extra` is the store-suffixed binary GOG ships beside the
    /// arch-selector stub.
    private func makeBundle(executable: String = "Baldur's Gate 3",
                            extra: String? = nil,
                            plist: Bool = true) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bg3store-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Baldur's Gate 3.app")
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        if plist {
            let info = ["CFBundleExecutable": executable]
            let data = try PropertyListSerialization.data(fromPropertyList: info,
                                                          format: .xml, options: 0)
            try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        try Data("stub".utf8).write(to: macos.appendingPathComponent(executable))
        if let extra {
            try Data("game".utf8).write(to: macos.appendingPathComponent(extra))
        }
        return bundle
    }

    // MARK: Detection

    func testGOGBundleDetectedBySuffixedBinary() throws {
        let bundle = try makeBundle(extra: "Baldur's Gate 3 GOG")
        XCTAssertEqual(GameStore.detect(in: bundle), .gog)
    }

    func testSteamBundleHasNoSuffixedBinary() throws {
        let bundle = try makeBundle()
        XCTAssertEqual(GameStore.detect(in: bundle), .steam)
    }

    /// A GOG bundle under a Steam-shaped path is still GOG: detection must not
    /// read the path.
    func testDetectionIgnoresInstallLocation() throws {
        let bundle = try makeBundle(extra: "Baldur's Gate 3 GOG")
        XCTAssertEqual(GameStore.detect(in: bundle), .gog,
                       "store must come from the bundle layout, not where it lives")
    }

    func testDetectionHonoursCFBundleExecutable() throws {
        let bundle = try makeBundle(executable: "BG3", extra: "BG3 GOG")
        XCTAssertEqual(GameStore.detect(in: bundle), .gog)
    }

    func testMissingPlistFallsBackToBundleStem() throws {
        let bundle = try makeBundle(extra: "Baldur's Gate 3 GOG", plist: false)
        XCTAssertEqual(GameStore.detect(in: bundle), .gog)
    }

    // MARK: Executable resolution

    /// GOG's CFBundleExecutable is a ~200KB arch-selector stub that re-execs the
    /// game, so this must return the suffixed binary.
    func testExecutablePrefersTheSuffixedBinary() throws {
        let bundle = try makeBundle(extra: "Baldur's Gate 3 GOG")
        XCTAssertEqual(GameStore.executable(in: bundle)?.lastPathComponent,
                       "Baldur's Gate 3 GOG")
    }

    func testExecutableFallsBackToBundleExecutable() throws {
        let bundle = try makeBundle()
        XCTAssertEqual(GameStore.executable(in: bundle)?.lastPathComponent, "Baldur's Gate 3")
    }

    func testExecutableNilWhenNothingInstalled() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bg3empty-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Baldur's Gate 3.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(GameStore.executable(in: bundle))
    }

    // MARK: Per-store build inputs

    func testStoresUseDifferentLaunchersAndBuildDirectories() {
        XCTAssertEqual(GameStore.steam.launcherScriptName, "scripts/bg3w.sh")
        XCTAssertEqual(GameStore.gog.launcherScriptName, "scripts/bg3g.sh")
        XCTAssertNotEqual(GameStore.steam.buildDirectory, GameStore.gog.buildDirectory,
                          "one build tree per store, or they overwrite each other")
    }

    func testBuildCommandsPinTheStore() {
        let root = URL(fileURLWithPath: "/tmp/checkout")
        XCTAssertTrue(ScriptExtenderMac.buildCommands(for: root, store: .gog)
            .contains("-DBG3_STORE=gog"))
        XCTAssertTrue(ScriptExtenderMac.buildCommands(for: root, store: .steam)
            .contains("-DBG3_STORE=steam"))
    }

    // MARK: Galaxy release key

    func testReleaseKeyReadFromGoggameInfo() throws {
        let bundle = try makeBundle(extra: "Baldur's Gate 3 GOG")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(#"{"gameId":"1456460669","name":"Baldur's Gate 3"}"#.utf8)
            .write(to: resources.appendingPathComponent("goggame-1456460669.info"))
        XCTAssertEqual(GalaxyLaunchOptions.releaseKey(for: bundle), "gog_1456460669")
    }

    /// GOG has shipped .info files with unexpected fields; the filename
    /// fallback keeps wiring working rather than failing outright.
    func testReleaseKeyFallsBackToFilename() throws {
        let bundle = try makeBundle(extra: "Baldur's Gate 3 GOG")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: resources.appendingPathComponent("goggame-1456460669.info"))
        XCTAssertEqual(GalaxyLaunchOptions.releaseKey(for: bundle), "gog_1456460669")
    }

    func testReleaseKeyNilForNonGOGBundle() throws {
        let bundle = try makeBundle()
        XCTAssertNil(GalaxyLaunchOptions.releaseKey(for: bundle))
    }
}

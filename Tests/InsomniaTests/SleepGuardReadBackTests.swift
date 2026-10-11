import XCTest
@testable import Insomnia

/// `pmset -a disablesleep 1` exiting 0 does not prove that sleep is disabled:
/// on macOS 26.6.2 (25G83) `pmset -g` reads SleepDisabled 1 for about 2 s,
/// then 0 for good. `sudo` and `pmset` are tiny `/bin/sh` scripts in a
/// private temp dir that record their calls, so nothing here runs sudo or
/// pmset or changes a power setting.
final class SleepGuardReadBackTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-readback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func script(_ name: String, _ body: String) throws -> String {
        let path = file(name)
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// A sudo that exits 0 and a pmset whose `-g` reports SleepDisabled as
    /// `reads`, both appending their arguments to `calls`.
    private func fakeGuard(reading reads: String) throws -> PmsetSleepGuard {
        let calls = file("calls")
        let sudo = try script("sudo", "printf 'sudo %s\\n' \"$*\" >> '\(calls)'")
        let pmset = try script("pmset", """
        printf 'pmset %s\\n' "$*" >> '\(calls)'
        printf 'System-wide power settings:\\n SleepDisabled\\t\\t%s\\n' '\(reads)'
        """)
        return PmsetSleepGuard(sudo: sudo, pmset: pmset, timeout: 5, stopGrace: 1, settle: 0.05)
    }

    private func calls() throws -> [String] {
        try String(contentsOfFile: file("calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private func disableSleep(_ sleepGuard: PmsetSleepGuard) async throws {
        let lock = RecoveryLock(url: dir.appendingPathComponent(".recovery.lock"))
        let handle = try XCTUnwrap(try lock.tryAcquire())
        defer { handle.release() }
        try await RecoveryLock.$held.withValue(handle) { try await sleepGuard.setSleepDisabled(true) }
    }

    /// pmset exits 0 but the bit reads 0 again after the settle time. The
    /// disable throws, so the start fails like any failed pmset instead of
    /// running a session that a closed lid ends in sleep.
    func testDisableThatMacOSPutsBackThrows() async throws {
        let sleepGuard = try fakeGuard(reading: "0")
        do {
            try await disableSleep(sleepGuard)
            XCTFail("a disable that macOS put back returned")
        } catch let error as SleepDisableRevertedError {
            XCTAssertTrue(error.localizedDescription.contains("SleepDisabled back to 0"), error.localizedDescription)
        }
        XCTAssertEqual(try calls(), ["sudo -n \(file("pmset")) -a disablesleep 1", "pmset -g"])
    }

    func testDisableThatHoldsReturnsAfterReadingItBack() async throws {
        let sleepGuard = try fakeGuard(reading: "1")
        try await disableSleep(sleepGuard)
        XCTAssertEqual(try calls(), ["sudo -n \(file("pmset")) -a disablesleep 1", "pmset -g"])
    }
}

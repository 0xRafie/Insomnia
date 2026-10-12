import XCTest
@testable import Insomnia

/// Stands in for the running app at every wait of `SessionCommandLine`:
/// takes the request, records it, writes `session` when set, and answers.
final class FakeRunningApp {
    var takes = true
    var answer: SessionCommandReply? = SessionCommandReply(error: nil)
    var session: Session?
    private(set) var requests: [String] = []
    private(set) var waits = 0

    func wait(paths: Paths) {
        waits += 1
        guard takes, let text = try? String(contentsOf: paths.sessionCommandFile, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: paths.sessionCommandFile)
        let line = text.trimmingCharacters(in: .newlines)
        requests.append(line)
        let store = Store(paths: paths)
        if let session { try? store.saveSession(session) }
        if let answer, let reply = SessionRequest(text: line)?.reply {
            try? store.write(answer, to: paths.sessionCommandReply(reply))
        }
    }
}

/// `Insomnia --session`: the request format, the app side (the manager runs
/// each command like its menu action and answers it; the watcher on the
/// support directory) and the command line that waits for the answer.
@MainActor
final class SessionCommandTests: XCTestCase {
    var h: Harness!
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() async throws {
        h = Harness()
        try h.home.paths.createDirectories()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    // MARK: Request format

    func testRequestsRoundTripThroughTheirText() {
        let requests = [
            SessionRequest(command: .start(seconds: 7200), reply: "4242-17"),
            SessionRequest(command: .extend(seconds: 600), reply: "1-2"),
            SessionRequest(command: .end, reply: "99"),
        ]
        for request in requests {
            XCTAssertEqual(SessionRequest(text: request.text), request, request.text)
        }
        XCTAssertEqual(requests.map(\.text), ["start 7200 4242-17", "extend 600 1-2", "end 99"])
    }

    func testMalformedRequestsAreRefused() {
        let texts = [
            "", "end", "start 7200", "start 0 1-2", "start -5 1-2", "start 1.5 1-2", "start +5 1-2",
            "start 2147483648 1-2", "extend abc 1-2", "stop 1-2", "start 7200 1-2 3", "end ../x",
            "end 1/2", "end a-b", "start  7200 1-2", "END 1-2", "end " + String(repeating: "1", count: 33),
        ]
        for text in texts {
            XCTAssertNil(SessionRequest(text: text), text)
        }
    }

    // MARK: The app side

    func testCommandsRunLikeTheirMenuActions() async throws {
        let m = h.makeManager()
        let started = await m.run(.start(seconds: 3600))
        XCTAssertNil(started)
        let session = try XCTUnwrap(m.session)
        XCTAssertEqual(session.endsAt, h.clock.now.addingTimeInterval(3600))
        XCTAssertEqual(try h.store.loadSession(), session)

        let again = await m.run(.start(seconds: 60))
        XCTAssertEqual(again, "a session is already running; use extend")
        XCTAssertEqual(m.session, session, "a second start changes nothing")

        let extended = await m.run(.extend(seconds: 600))
        XCTAssertNil(extended)
        XCTAssertEqual(m.session?.endsAt, session.endsAt.addingTimeInterval(600))

        let ended = await m.run(.end)
        XCTAssertNil(ended)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())

        let extendNothing = await m.run(.extend(seconds: 600))
        XCTAssertEqual(extendNothing, "no session is running")
        let endNothing = await m.run(.end)
        XCTAssertNil(endNothing, "ending with no session is already done")
    }

    func testAFailedStartAnswersWithTheReason() async throws {
        h.guardFake.throwOn = ["disablesleep 1"]
        let m = h.makeManager()
        let answer = await m.run(.start(seconds: 3600))
        let error = try XCTUnwrap(answer)
        XCTAssertTrue(error.contains("password is required"), error)
        XCTAssertNil(m.session)
    }

    func testServeAnswersInTheRequestsReplyFile() async throws {
        let m = h.makeManager()
        await m.serve(SessionRequest(command: .start(seconds: 60), reply: "7-7"))
        XCTAssertNotNil(m.session)
        XCTAssertEqual(try reply("7-7"), SessionCommandReply(error: nil))

        await m.serve(SessionRequest(command: .start(seconds: 60), reply: "7-8"))
        XCTAssertEqual(try reply("7-8"), SessionCommandReply(error: "a session is already running; use extend"))
    }

    // MARK: The watcher

    func testTheWatcherServesAFreshRequestAndRemovesIt() throws {
        let watcher = SessionCommandWatcher()
        var got: [SessionRequest] = []
        watcher.onRequest = { got.append($0) }
        watcher.start(directory: h.home.paths.appSupport, file: h.home.paths.sessionCommandFile)
        defer { watcher.stop() }

        try drop("start 60 1-1")
        watcher.consume()

        XCTAssertEqual(got, [SessionRequest(command: .start(seconds: 60), reply: "1-1")])
        XCTAssertFalse(exists(h.home.paths.sessionCommandFile))
    }

    func testTheWatcherDropsStaleAndMalformedRequestsWithoutServingThem() throws {
        let watcher = SessionCommandWatcher()
        var got: [SessionRequest] = []
        watcher.onRequest = { got.append($0) }
        watcher.start(directory: h.home.paths.appSupport, file: h.home.paths.sessionCommandFile)
        defer { watcher.stop() }

        // The command line that wrote it gave up long ago.
        try drop("start 60 1-1", age: SessionCommandLine.staleAfter + 1)
        watcher.consume()
        try drop("start sixty 1-1")
        watcher.consume()

        XCTAssertEqual(got, [])
        XCTAssertFalse(exists(h.home.paths.sessionCommandFile))
    }

    func testARequestWrittenBeforeTheWatchStartsIsServedAndOldAnswersAreCleared() throws {
        let leftover = h.home.paths.sessionCommandReply("3-3")
        try h.store.write(SessionCommandReply(error: nil), to: leftover)
        try drop("end 5-5")
        let watcher = SessionCommandWatcher()
        var got: [SessionRequest] = []
        watcher.onRequest = { got.append($0) }

        watcher.start(directory: h.home.paths.appSupport, file: h.home.paths.sessionCommandFile)
        defer { watcher.stop() }

        XCTAssertEqual(got, [SessionRequest(command: .end, reply: "5-5")])
        XCTAssertFalse(exists(leftover), "nobody waits for an answer from before the launch")
    }

    // MARK: The command line

    func testAnAnsweredStartPrintsTheSessionItStarted() {
        let app = FakeRunningApp()
        let now = h.clock.now
        app.session = Session(startedAt: now, endsAt: now.addingTimeInterval(7200))

        let output = commandLine(["start", "7200"], app: app)

        XCTAssertEqual(app.requests, ["start 7200 9-9"])
        XCTAssertEqual(output, .init(lines: ["running until \(iso(now.addingTimeInterval(7200))) (2h left)"], status: 0))
        XCTAssertFalse(exists(h.home.paths.sessionCommandReply("9-9")), "the answer is removed once read")
    }

    func testARefusalIsPrintedAndExitsOne() {
        let app = FakeRunningApp()
        app.answer = SessionCommandReply(error: "a session is already running; use extend")

        XCTAssertEqual(commandLine(["start", "60"], app: app), .init(lines: ["a session is already running; use extend"], status: 1))
    }

    func testNothingTakingTheRequestMeansTheAppIsNotRunningAndTheRequestIsTakenBack() throws {
        let app = FakeRunningApp()
        app.takes = false

        let output = try XCTUnwrap(commandLine(["end"], app: app))

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.lines.first?.contains("not running") == true, "\(output.lines)")
        XCTAssertFalse(exists(h.home.paths.sessionCommandFile), "a request left behind could run at the next launch")
        XCTAssertEqual(Double(app.waits) * SessionCommandLine.pollInterval, SessionCommandLine.claimTimeout, accuracy: 0.5)
    }

    func testARunningAppThatTakesNothingIsNamedAsAnOlderVersion() throws {
        let app = FakeRunningApp()
        app.takes = false

        let output = try XCTUnwrap(commandLine(["end"], app: app, appRunning: true))

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.lines.first?.contains("version without --session") == true, "\(output.lines)")
        XCTAssertFalse(exists(h.home.paths.sessionCommandFile))
    }

    func testATakenRequestWithNoAnswerTimesOut() throws {
        let app = FakeRunningApp()
        app.answer = nil

        let output = try XCTUnwrap(commandLine(["extend", "600"], app: app))

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.lines.first?.contains("did not answer") == true, "\(output.lines)")
    }

    func testARequestStillWaitingIsNotReplaced() throws {
        let file = h.home.paths.sessionCommandFile
        try Data("start 60 1-1\n".utf8).write(to: file)
        let app = FakeRunningApp()
        app.takes = false

        let output = try XCTUnwrap(commandLine(["end"], app: app))

        XCTAssertEqual(output.status, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "start 60 1-1\n", "the other request is left as it was")
    }

    func testStatusReadsTheSessionFileAndSendsNothing() throws {
        XCTAssertEqual(commandLine(["status"]), .init(lines: ["no session is running"], status: 0))

        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(90 * 60)))

        XCTAssertEqual(commandLine(["status"]), .init(lines: ["running until \(iso(now.addingTimeInterval(5400))) (1h 30m left)"], status: 0))
        XCTAssertFalse(exists(h.home.paths.sessionCommandFile))
    }

    func testUsageErrorsExit64AndOtherArgumentsAreNotThisMode() {
        for words in [[], ["start"], ["start", "0"], ["start", "1h"], ["stop"], ["status", "now"], ["end", "now"]] {
            XCTAssertEqual(commandLine(words)?.status, SessionCommandLine.usageStatus, "\(words)")
        }
        XCTAssertNil(SessionCommandLine.run(["--resume-frozen", "5"], paths: h.home.paths))
        XCTAssertNil(SessionCommandLine.run([], paths: h.home.paths))
    }

    /// Scripts read the bundle's key before they run the binary.
    func testTheBundleDeclaresTheSessionCommandVersion() throws {
        // .../Tests/InsomniaTests/SessionCommandTests.swift -> .../Resources/Info.plist
        let info = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        XCTAssertEqual(plist["InsomniaSessionCommandVersion"] as? Int, SessionCommandLine.version)
    }

    // MARK: Helpers

    private func commandLine(_ words: [String], app: FakeRunningApp = FakeRunningApp(), appRunning: Bool = false) -> SessionCommandLine.Output? {
        let paths = h.home.paths
        let now = h.clock.now
        return SessionCommandLine.run(
            ["--session"] + words, paths: paths, now: { now }, timeZone: utc, replyName: "9-9", appRunning: { appRunning }
        ) { _ in
            app.wait(paths: paths)
        }
    }

    /// Puts `text` where the command line puts a request, written `age`
    /// seconds ago.
    private func drop(_ text: String, age: TimeInterval = 0) throws {
        let file = h.home.paths.sessionCommandFile
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    private func reply(_ name: String) throws -> SessionCommandReply? {
        try h.store.read(SessionCommandReply.self, from: h.home.paths.sessionCommandReply(name))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func iso(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.timeZone = utc
        return format.string(from: date)
    }
}

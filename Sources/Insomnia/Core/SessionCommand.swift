import AppKit
import Darwin
import Foundation

/// A session action that arrives from outside the menu, through
/// `Insomnia --session` (`SessionCommandLine`). Each runs like its menu
/// counterpart: `start` like the start pills, `extend` like the extend
/// pills, `end` like hold-to-end.
enum SessionCommand: Equatable, Sendable {
    case start(seconds: Int)
    case extend(seconds: Int)
    case end

    static let alreadyRunning = "a session is already running; use extend"
}

/// One command as it travels through `Paths.sessionCommandFile`: a single
/// line, `start <seconds> <reply>`, `extend <seconds> <reply>` or
/// `end <reply>`. `<seconds>` is a whole number from 1 to `Int32.max`
/// (`SessionMath` still caps a session at `Config.maxDuration`). `<reply>`
/// names the file the app answers in (`Paths.sessionCommandReply`) and holds
/// digits and `-` only, so the answer cannot land outside the support
/// directory.
struct SessionRequest: Equatable, Sendable {
    let command: SessionCommand
    let reply: String

    init(command: SessionCommand, reply: String) {
        self.command = command
        self.reply = reply
    }

    /// nil for anything that is not exactly one of the three shapes.
    init?(text: String) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let reply = words.popLast(), Self.isReplyName(reply) else { return nil }
        if words == ["end"] {
            command = .end
        } else if words.count == 2, let seconds = Self.seconds(words[1]) {
            switch words[0] {
            case "start": command = .start(seconds: seconds)
            case "extend": command = .extend(seconds: seconds)
            default: return nil
            }
        } else {
            return nil
        }
        self.reply = reply
    }

    var text: String {
        switch command {
        case let .start(seconds): "start \(seconds) \(reply)"
        case let .extend(seconds): "extend \(seconds) \(reply)"
        case .end: "end \(reply)"
        }
    }

    /// Digits only, from 1 to `Int32.max`.
    static func seconds(_ word: String) -> Int? {
        guard !word.isEmpty, word.utf8.allSatisfy(isDigit),
              let seconds = Int(word), seconds > 0, seconds <= Int(Int32.max)
        else { return nil }
        return seconds
    }

    /// 1 to 32 characters, digits and `-`.
    static func isReplyName(_ word: String) -> Bool {
        (1...32).contains(word.utf8.count) && word.utf8.allSatisfy { isDigit($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

/// The app's answer to one request, at `Paths.sessionCommandReply`.
struct SessionCommandReply: Codable, Equatable, Sendable {
    /// nil when the command took effect, otherwise why not, for the person
    /// or script that sent it.
    var error: String?
}

extension SessionManager {
    /// Runs `command` like its menu counterpart. nil when this call took
    /// effect, otherwise why not. Only a failure recorded during this call
    /// is given as the reason; an older `lastError` is about something else.
    func run(_ command: SessionCommand) async -> String? {
        let fails = failCount
        var reason: String? { failCount == fails ? nil : lastError }
        switch command {
        case let .start(seconds):
            if session != nil { return SessionCommand.alreadyRunning }
            if await tryStart(duration: TimeInterval(seconds)) { return nil }
            if session != nil { return SessionCommand.alreadyRunning }
            return reason ?? "the session did not start; see the log"
        case let .extend(seconds):
            // A start still queued or in flight has no session yet.
            if session == nil { await waitForQueuedWork() }
            guard session != nil else { return "no session is running" }
            if await tryExtend(by: TimeInterval(seconds)) { return nil }
            if session == nil { return "the session ended first" }
            return reason ?? "the session was not extended; it may already be as long as a session can be"
        case .end:
            // A start still queued or in flight would run on after this
            // answer; wait for it and end what it started.
            if session == nil { await waitForQueuedWork() }
            guard session != nil else { return nil }
            switch await end(reason: .user) {
            case .restored:
                return nil
            case .incomplete:
                return reason ?? "the session ended, but not every change is undone yet; see the log"
            case .locked:
                return "the recovery lock is held by another process, so nothing changed; Insomnia retries the end"
            case .sessionRetained:
                return "session.json could not be removed; Insomnia retries the end"
            case .journalUnreadable:
                return "state.json cannot be read, so nothing was undone; see the log"
            case let .privilegedCommandRunning(pid):
                return "a sudo pmset (pid \(pid)) is still running; the end finishes when it exits"
            }
        }
    }

    /// Runs `request` and writes the answer where `Insomnia --session`
    /// waits for it.
    func serve(_ request: SessionRequest) async {
        let error = await run(request.command)
        Log.info("session command \(request.text): \(error ?? "done")")
        do {
            try store.write(SessionCommandReply(error: error), to: paths.sessionCommandReply(request.reply))
        } catch {
            Log.error("session command: could not answer \(request.reply): \(error.localizedDescription)")
        }
    }
}

/// Watches the support directory for `Paths.sessionCommandFile` and hands
/// each request to `onRequest` on the main actor. AppDelegate starts it once
/// the launch reconcile has run, and it runs for as long as the app does,
/// with or without a session. The file is the same trust boundary as
/// config.json and the simulate-lid trigger: only this user can write the
/// directory. A request is served only while it is fresh: one written more
/// than `SessionCommandLine.staleAfter` seconds before the app reads it is
/// claimed, logged and dropped, never run, because the command line that
/// wrote it has given up by then.
@MainActor
final class SessionCommandWatcher {
    var onRequest: ((SessionRequest) -> Void)?

    private var source: (any DispatchSourceFileSystemObject)?
    private var directory: URL?
    private var file: URL?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func start(directory: URL, file: URL) {
        guard source == nil else { return }
        self.directory = directory
        self.file = file
        // Nobody waits for an answer from before this launch: a command
        // line waits only while the app that took its request runs.
        removeAnswers(olderThan: 0)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.error("session command: cannot watch \(directory.path): \(String(cString: strerror(errno)))")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in
            Task { @MainActor in self?.consume() }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
        // A request written before the watch began has no event of its own.
        consume()
    }

    func stop() {
        source?.cancel()
        source = nil
        directory = nil
        file = nil
    }

    /// Serves every request on disk. The watcher calls this on each
    /// directory write; internal so tests can drive it without the watcher.
    /// Directory events coalesce, so keep claiming until the path is empty.
    func consume() {
        while let claimed = claim() {
            let text = claimed.text
            guard let written = claimed.written, now().timeIntervalSince(written) <= SessionCommandLine.staleAfter else {
                Log.info("session command: ignored stale \"\(text)\"")
                continue
            }
            guard let request = SessionRequest(text: text) else {
                Log.error("session command: ignoring \"\(text)\" (expected start <seconds>, extend <seconds> or end, then a reply name)")
                continue
            }
            // Answers whose command line stopped waiting go with each new
            // request, so a long-running app does not collect them.
            removeAnswers(olderThan: SessionCommandLine.replyTimeout)
            onRequest?(request)
        }
    }

    // MARK: Private

    /// Claims the request before reading it, as `LidSimulation` does:
    /// `rename(2)` to a per-process path is atomic, so a command line taking
    /// its request back and the app cannot both have it. `written` is the
    /// file's modification time, which the rename keeps. nil when nothing
    /// was claimed.
    private func claim() -> (text: String, written: Date?)? {
        guard let file else { return nil }
        let claimed = file.appendingPathExtension("claimed.\(getpid())")
        guard rename(file.path, claimed.path) == 0 else {
            let code = errno
            if code != ENOENT {
                Log.error("session command: cannot claim \(file.path): \(String(cString: strerror(code)))")
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(at: claimed) }
        let written = (try? FileManager.default.attributesOfItem(atPath: claimed.path))?[.modificationDate] as? Date
        let text = (try? String(contentsOf: claimed, encoding: .utf8)) ?? ""
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), written)
    }

    private func removeAnswers(olderThan age: TimeInterval) {
        guard let directory, let file else { return }
        let prefix = file.lastPathComponent + ".reply."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let url = directory.appendingPathComponent(name)
            let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if now().timeIntervalSince(written ?? .distantPast) >= age {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// `Insomnia --session start <seconds> | extend <seconds> | end | status`.
/// One-shot mode for scripts and agents. It drives the running menu bar app
/// and changes nothing itself, so the session it starts is the one the menu
/// bar counts down, ends from the menu like any other, and keeps the
/// battery and thermal floors. It puts one `SessionRequest` at
/// `Paths.sessionCommandFile` for the app's `SessionCommandWatcher`, then
/// waits for the app's `SessionCommandReply`. `status` only reads
/// session.json.
///
/// Prints one line. Exits 0 when the command took effect (and for `status`
/// whenever session.json can be read), 1 when the app refused the command,
/// did not take it within `claimTimeout`, or did not answer within
/// `replyTimeout`, and 64 on a usage error.
enum SessionCommandLine {
    static let flag = "--session"
    /// `InsomniaSessionCommandVersion` in Resources/Info.plist. A script
    /// that may meet an older build reads it before running the binary,
    /// because a build without this mode opens the menu bar app instead.
    static let version = 1
    /// EX_USAGE from sysexits(3).
    static let usageStatus: Int32 = 64
    /// How long a running app has to take the request before the command
    /// line takes it back.
    static let claimTimeout: TimeInterval = 2
    /// A request older than this when the app reads it is dropped, and a
    /// command line removes one this old that a killed command line left.
    /// Longer than `claimTimeout` plus a busy main thread.
    static let staleAfter: TimeInterval = 5
    /// How long the app has to answer. A start arms the backstop and runs
    /// pmset, which has its own 20 s limit, then reads it back.
    static let replyTimeout: TimeInterval = 60
    static let pollInterval: TimeInterval = 0.1

    struct Output: Equatable, Sendable {
        let lines: [String]
        let status: Int32
    }

    /// What runs under this bundle id besides this command line.
    enum RunningApp: Sendable {
        case none
        /// A build whose Info.plist lacks this interface.
        case older
        case current
    }

    /// nil when `arguments` (the command line without the executable) do
    /// not ask for this mode. `runningApp` explains a request nothing took.
    /// `wait` sleeps between reads of the files.
    static func run(
        _ arguments: [String],
        paths: Paths = .fromEnvironment(),
        now: () -> Date = Date.init,
        timeZone: TimeZone = .current,
        replyName: String = "\(getpid())-\(UInt32.random(in: .min ... .max))",
        runningApp: () -> RunningApp = runningApp,
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Output? {
        guard arguments.first == flag else { return nil }
        let words = Array(arguments.dropFirst())
        let store = Store(paths: paths)
        if words == ["status"] {
            do {
                return Output(lines: [describe(try store.loadSession(), now: now(), timeZone: timeZone)], status: 0)
            } catch {
                return failure(error.localizedDescription)
            }
        }
        guard let request = SessionRequest(text: (words + [replyName]).joined(separator: " ")) else {
            return Output(lines: ["usage: Insomnia --session start <seconds> | extend <seconds> | end | status"], status: usageStatus)
        }

        let file = paths.sessionCommandFile
        var waited: TimeInterval = 0
        var mine: ino_t
        do {
            // Another command line's request still waiting is never
            // replaced; one a killed command line left goes.
            while true {
                if let published = try publish(request.text + "\n", at: file) {
                    mine = published
                    break
                }
                if let there = stat(file), Date().timeIntervalSince(there.modified) > staleAfter {
                    _ = takeBack(file, inode: there.inode)
                    continue
                }
                guard waited < claimTimeout else {
                    return failure("another command is still waiting for Insomnia; try again")
                }
                wait(pollInterval)
                waited += pollInterval
            }
        } catch {
            return failure("cannot write \(file.path): \(error.localizedDescription)")
        }

        // Only this command line's own file counts: once the app has taken
        // it, another request may be at the path already.
        waited = 0
        while stat(file)?.inode == mine {
            if waited >= claimTimeout {
                guard takeBack(file, inode: mine) else { break }  // the app claimed it just now
                switch runningApp() {
                case .none:
                    return failure("Insomnia is not running, so nothing took the command; open the app and try again")
                case .older:
                    return failure("the Insomnia that is running is a version without --session; quit it and open the new one")
                case .current:
                    return failure("Insomnia did not take the command within \(Int(claimTimeout)) s; it may still be starting, so try again")
                }
            }
            wait(pollInterval)
            waited += pollInterval
        }

        let replyFile = paths.sessionCommandReply(request.reply)
        waited = 0
        while true {
            if let data = try? Data(contentsOf: replyFile),
               let reply = try? JSONDecoder().decode(SessionCommandReply.self, from: data) {
                try? FileManager.default.removeItem(at: replyFile)
                if let error = reply.error { return failure(error) }
                return Output(lines: [describe(try? store.loadSession(), now: now(), timeZone: timeZone)], status: 0)
            }
            guard waited < replyTimeout else {
                return failure("Insomnia took the command but did not answer within \(Int(replyTimeout)) s; see \(paths.logFile.path)")
            }
            wait(pollInterval)
            waited += pollInterval
        }
    }

    /// `running until <ISO 8601 time> (<remaining> left)` or
    /// `no session is running`. The remaining time is rounded up to the
    /// minute, so a session just started for 2m reads 2m, not 1m.
    static func describe(_ session: Session?, now: Date, timeZone: TimeZone) -> String {
        guard let session, !session.isExpired(at: now) else { return "no session is running" }
        let format = ISO8601DateFormatter()
        format.timeZone = timeZone
        let left = (session.remaining(at: now) / 60).rounded(.up) * 60
        return "running until \(format.string(from: session.endsAt)) (\(SessionMath.formatRemaining(left)) left)"
    }

    /// Another process of this bundle id, that is the menu bar app, and
    /// whether its bundle declares this interface. This command line is not
    /// a registered application, and its own pid is left out in case it is.
    static func runningApp() -> RunningApp {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier)
            .filter { $0.processIdentifier != getpid() }
        guard let app = apps.first else { return .none }
        guard let info = app.bundleURL?.appendingPathComponent("Contents/Info.plist"),
              let plist = NSDictionary(contentsOf: info),
              plist["InsomniaSessionCommandVersion"] as? Int == version
        else { return .older }
        return .current
    }

    // MARK: Private

    private static func failure(_ line: String) -> Output {
        Output(lines: [line], status: 1)
    }

    /// Puts `text` at `file` only when nothing is there, through `link(2)`
    /// from a private file, so two command lines never replace each other's
    /// request. The published file's inode, or nil when a request is there.
    private static func publish(_ text: String, at file: URL) throws -> ino_t? {
        let tmp = file.appendingPathExtension("tmp.\(getpid())")
        try Data(text.utf8).write(to: tmp)
        defer { unlink(tmp.path) }
        guard let inode = stat(tmp)?.inode else { throw POSIXError(.EIO) }
        if link(tmp.path, file.path) == 0 { return inode }
        let code = errno
        if code == EEXIST { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Takes the request at `file` away so that it cannot run later, if it
    /// is the one with `inode`. A different one taken in a race goes back.
    /// false when nothing with that inode was taken.
    private static func takeBack(_ file: URL, inode: ino_t) -> Bool {
        let taken = file.appendingPathExtension("taken.\(getpid())")
        guard rename(file.path, taken.path) == 0 else { return false }
        defer { unlink(taken.path) }
        if stat(taken)?.inode == inode { return true }
        _ = link(taken.path, file.path)
        return false
    }

    private static func stat(_ url: URL) -> (inode: ino_t, modified: Date)? {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return (st.st_ino, modified)
    }
}

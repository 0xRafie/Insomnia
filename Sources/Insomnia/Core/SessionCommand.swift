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
    /// Runs `command` like its menu counterpart. nil when it took effect,
    /// otherwise why not.
    func run(_ command: SessionCommand) async -> String? {
        switch command {
        case let .start(seconds):
            if session != nil { return "a session is already running; use extend" }
            await start(duration: TimeInterval(seconds))
            return isActive ? nil : (lastError ?? "the session did not start")
        case let .extend(seconds):
            guard let before = session else { return "no session is running" }
            await extend(by: TimeInterval(seconds))
            if let after = session, after.endsAt > before.endsAt { return nil }
            return lastError ?? "the session was not extended"
        case .end:
            guard isActive else { return nil }
            let outcome = await end(reason: .user)
            return isActive ? "the session has not ended yet (\(outcome))" : nil
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
/// each request to `onRequest` on the main actor. Runs for as long as the
/// app does, with or without a session. The file is the same trust
/// boundary as config.json and the simulate-lid trigger: only this user can
/// write the directory. A request is served only while it is fresh: one
/// written more than `SessionCommandLine.staleAfter` seconds before the app
/// reads it is claimed, logged and dropped, never run, because the command
/// line that wrote it has given up by then.
@MainActor
final class SessionCommandWatcher {
    var onRequest: ((SessionRequest) -> Void)?

    private var source: (any DispatchSourceFileSystemObject)?
    private var file: URL?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func start(directory: URL, file: URL) {
        guard source == nil else { return }
        self.file = file
        // Answers left from before this launch have nobody waiting: a
        // command line waits only while the app that took its request runs.
        let prefix = file.lastPathComponent + ".reply."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
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
        // A request written while the app was launching has no directory
        // event of its own.
        consume()
    }

    func stop() {
        source?.cancel()
        source = nil
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
/// did not take it within `claimTimeout` (it is not running), or did not
/// answer within `replyTimeout`, and 64 on a usage error.
enum SessionCommandLine {
    static let flag = "--session"
    /// EX_USAGE from sysexits(3).
    static let usageStatus: Int32 = 64
    /// How long a running app has to take the request before the command
    /// line takes it back.
    static let claimTimeout: TimeInterval = 2
    /// A request older than this when the app reads it is dropped. Longer
    /// than `claimTimeout` plus a busy main thread.
    static let staleAfter: TimeInterval = 5
    /// How long the app has to answer. A start arms the backstop and runs
    /// pmset, which has its own 20 s limit, then reads it back.
    static let replyTimeout: TimeInterval = 60
    static let pollInterval: TimeInterval = 0.1

    struct Output: Equatable, Sendable {
        let lines: [String]
        let status: Int32
    }

    /// nil when `arguments` (the command line without the executable) do
    /// not ask for this mode. `appRunning` tells a menu bar app that left
    /// the request alone (an older build) from no app. `wait` sleeps between
    /// reads of the files.
    static func run(
        _ arguments: [String],
        paths: Paths = .fromEnvironment(),
        now: () -> Date = Date.init,
        timeZone: TimeZone = .current,
        replyName: String = "\(getpid())-\(UInt32.random(in: .min ... .max))",
        appRunning: () -> Bool = appIsRunning,
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
        do {
            // Another command line's request still waiting is never replaced.
            while try !publish(request.text + "\n", at: file) {
                guard waited < claimTimeout else {
                    return failure("another command is still waiting for Insomnia; try again")
                }
                wait(pollInterval)
                waited += pollInterval
            }
        } catch {
            return failure("cannot write \(file.path): \(error.localizedDescription)")
        }

        waited = 0
        while FileManager.default.fileExists(atPath: file.path) {
            if waited >= claimTimeout {
                if takeBack(file) {
                    return failure(appRunning()
                        ? "the Insomnia that is running did not take the command; it is a version without --session, so quit it and open this one"
                        : "Insomnia is not running, so nothing took the command; open the app and try again")
                }
                break  // the app claimed it just now
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
    /// `no session is running`.
    static func describe(_ session: Session?, now: Date, timeZone: TimeZone) -> String {
        guard let session, !session.isExpired(at: now) else { return "no session is running" }
        let format = ISO8601DateFormatter()
        format.timeZone = timeZone
        return "running until \(format.string(from: session.endsAt)) (\(SessionMath.formatRemaining(session.remaining(at: now))) left)"
    }

    /// Whether another process of this bundle runs, that is the menu bar
    /// app. This command line is not a registered application, and its own
    /// pid is left out in case it ever is.
    static func appIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier)
            .contains { $0.processIdentifier != getpid() }
    }

    // MARK: Private

    private static func failure(_ line: String) -> Output {
        Output(lines: [line], status: 1)
    }

    /// Puts `text` at `file` only when nothing is there, through `link(2)`
    /// from a private file, so two command lines never replace each other's
    /// request. false when a request is already there.
    private static func publish(_ text: String, at file: URL) throws -> Bool {
        let tmp = file.appendingPathExtension("tmp.\(getpid())")
        try Data(text.utf8).write(to: tmp)
        defer { unlink(tmp.path) }
        if link(tmp.path, file.path) == 0 { return true }
        let code = errno
        if code == EEXIST { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Takes an unclaimed request back so that it cannot run later. false
    /// when the app claimed it first.
    private static func takeBack(_ file: URL) -> Bool {
        let mine = file.appendingPathExtension("taken.\(getpid())")
        guard rename(file.path, mine.path) == 0 else { return false }
        unlink(mine.path)
        return true
    }
}

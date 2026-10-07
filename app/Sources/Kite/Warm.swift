import AppKit

// Penpal's agents answer sooner (claude-kite #254, Jason: "lets optimize this 100%"):
//   a claude started ahead (`kite warm`): the next Enhance or Guide me run skips claude's start-up, about
//     0.7 to 1 s. A fresh claude for each run, so one ask never sees another; for a Guide follow-up, one
//     started already resuming that guide's session. It stops by itself after 10 idle minutes.
//   the run's own status file, read every 0.1 s, instead of the agent list (re-read every 1.5 s), which
//     added up to 1.9 s before Penpal noticed an answer.
// Without a ready claude (the first run, or a follow-up of another session), it's a plain `kite run`.

// A run's state, straight from its folder (~/.kite/agents/<agent>/runs/<id>).
struct RunState {
    let status: String      // working, done, error, died
    let result: String?
    let error: String?
    let session: String?
    var errorKind: String? = nil  // Claude Code's own word for it, e.g. model_not_found (#302)

    static func read(agent: String, id: String) -> RunState? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kite/agents/\(agent)/runs/\(id)")
        func text(_ f: String) -> String? {
            (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let status = text("status") else { return nil }
        return RunState(status: status, result: text("result.md"), error: text("stderr.txt").map { String($0.suffix(600)) }.flatMap { $0.isEmpty ? nil : $0 },
                        session: text("session_id"), errorKind: text("error_kind"))
    }

    // What went wrong, in plain words for the panel (#310: the helper's own text can name its files and folders); its raw
    // text goes to the log.
    var plainProblem: String? {
        guard status != "done" else { return nil }
        if let e = error { Log.line("run problem (\(errorKind ?? "-")): \(e.prefix(300))") }
        switch errorKind {
        case "authentication_failed": return "Your Claude Code isn't logged in. Open Claude Code, log in, then try again."
        case "rate_limit": return "Your Claude plan's limit is reached for now. Try again later."
        case "model_not_found": return "Your Claude Code can't run that model. Update Claude Code, or pick another in Settings › Magic."
        default: return error == nil ? nil : "Claude Code stopped with an error. Try again; if it keeps happening, Settings › General › Show log in Finder has the details."
        }
    }

    // Calls `done` once the run is no longer working, checking every 0.1 s (at most 5 minutes).
    @MainActor static func watch(agent: String, id: String, done: @escaping @MainActor (RunState) -> Void) {
        let started = Date.now
        func check() {
            if let s = read(agent: agent, id: id), s.status != "working" { return done(s) }
            if Date.now.timeIntervalSince(started) > 300 { return done(RunState(status: "error", result: nil, error: "No answer after 5 minutes.", session: nil)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { check() } }
        }
        check()
    }
}

@MainActor
final class WarmAgent {
    static let enhance = WarmAgent("enhance")
    static let guide = WarmAgent("guide")

    let agent: String
    private var process: Process?
    private var input: FileHandle?
    private var resume: String?          // the session this claude resumes, if any
    private var model: String?           // the model it was started on
    private var ready = false
    private var used = false
    private var started: ((String?) -> Void)?
    private var buffer = ""

    init(_ agent: String) { self.agent = agent }
    // The model this agent's runs ask: Enhance's is picked in Settings (#293); Guide me's is its agent's own (Sonnet).
    var picked: String? { agent == "enhance" ? Enhance.pickedModelArg : agent == "guide" ? Guide.pickedModelArg : nil }  // #307
    var isReady: Bool { ready && !used && process?.isRunning == true }

    // Have a claude ready for the next run (resuming `session`, for a follow-up). Cheap when one is.
    func prepare(resume session: String? = nil) {
        if let p = process, p.isRunning, !used, resume == session, model == picked { return }
        stop()
        guard let root = Kite.root else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli)
        p.arguments = ["warm", agent] + (session.map { ["--resume", $0] } ?? []) + (picked.map { ["--model", $0] } ?? [])
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Kite.path
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.take(s) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.process === p else { return }
                self.process = nil; self.ready = false
                if let s = self.started { self.started = nil; s(nil) }  // it went away mid-request: say so
            } }
        }
        do { try p.run() } catch { return }
        process = p; input = inPipe.fileHandleForWriting; resume = session; model = picked; ready = false; used = false; buffer = ""
    }

    private func take(_ s: String) {
        buffer += s
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]); buffer = String(buffer[buffer.index(after: nl)...])
            if line == "ready" { ready = true; Log.line("warm \(agent): ready\(resume == nil ? "" : " (resuming)")") }
            else if line.hasSuffix(" working"), let s = started {  // "<agent>/<run> working"
                started = nil
                s(line.split(separator: " ").first?.split(separator: "/").last.map(String.init))
            }
        }
    }

    // Starts the run on the ready claude, if there is one for this session. False: use `kite run` instead.
    func run(_ text: String, png: Data?, context: String?, resume session: String?, started: @escaping (String?) -> Void) -> Bool {
        guard let p = process, p.isRunning, ready, !used, resume == session, model == picked, let input else { return false }
        let tmp = FileManager.default.temporaryDirectory
        var req: [String: Any] = ["text": text]
        if let png {
            let f = tmp.appendingPathComponent("kite-warm-\(UUID().uuidString).png")
            if (try? png.write(to: f)) != nil { req["image"] = f.path }
        }
        if let context {
            let f = tmp.appendingPathComponent("kite-warm-\(UUID().uuidString).md")
            if (try? context.write(to: f, atomically: true, encoding: .utf8)) != nil { req["context"] = f.path }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: req) else { return false }
        used = true
        self.started = { id in
            for k in ["image", "context"] { if let f = req[k] as? String { try? FileManager.default.removeItem(atPath: f) } }  // copied into the run
            started(id)
        }
        input.write(data + Data("\n".utf8))
        Log.line("warm \(agent): run started on the ready claude")
        return true
    }

    func stop() {
        try? input?.close()  // `kite warm` lets claude go when we do
        process = nil; input = nil; ready = false; used = false
    }

    // A run of this agent, on the ready claude when there is one, else `kite run` / `kite follow`.
    // `follow` is the run this one continues (its session is resumed).
    // `model`: this run on another model than the agent's pick (Enhance's fallback, #302), so never on the ready claude.
    static func start(_ agent: WarmAgent, _ text: String, png: Data?, context: String?, follow: String?, model: String? = nil,
                      started: @escaping @MainActor (String?) -> Void) {
        let session = follow.flatMap { RunState.read(agent: agent.agent, id: $0)?.session }
        let t0 = Date.now
        let onStart: (String?) -> Void = { id in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                Log.line("\(agent.agent): run started in \(Int(Date.now.timeIntervalSince(t0) * 1000))ms")
                started(id)
            } }
        }
        if model == nil, agent.run(text, png: png, context: context, resume: session, started: onStart) { return }
        AgentStore.shared.runAgent(agent.agent, text, png: png, context: context, follow: follow, model: model ?? agent.picked) { id in onStart(id) }
    }
}

// --time-agents: one real Enhance ask (the sign-up one, with its picture), as Penpal sees it: from the
// call until the answer is in hand. Three ways, six times each: before #254 (kite run, the agent list
// polled), kite run with the run's status file, and a claude started ahead.
@MainActor
func timeAgents() {
    _ = NSApplication.shared
    let src = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kite/agents/enhance/runs/20261003-081822")
    guard let text = try? String(contentsOf: src.appendingPathComponent("input.md"), encoding: .utf8),
          let png = try? Data(contentsOf: src.appendingPathComponent("input.png")) else { return print("no input") }
    func spin(_ until: () -> Bool) { while !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
    var rows: [(String, Double)] = []
    for way in ["before", "cold", "warm"] {
        for _ in 0..<6 {
            if way == "warm" { WarmAgent.enhance.prepare(); spin { WarmAgent.enhance.isReady }; RunLoop.main.run(until: Date().addingTimeInterval(1)) }
            let t0 = Date.now
            let got = Got()
            if way == "before" {
                AgentStore.shared.runAgent("enhance", text, png: png) { id in
                    guard let id else { got.at = .now; return }
                    @MainActor func poll() {  // every 0.4 s, from the agent list, as Guide and Enhance did
                        if let r = AgentStore.shared.run(id), r.status != "working" { got.at = .now; return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { poll() } }
                    }
                    poll()
                }
            } else {
                if way == "cold" { WarmAgent.enhance.stop() }
                WarmAgent.start(.enhance, text, png: png, context: nil, follow: nil) { id in
                    guard let id else { got.at = .now; return }
                    RunState.watch(agent: "enhance", id: id) { _ in got.at = .now }
                }
            }
            spin { got.at != nil }
            let s = got.at!.timeIntervalSince(t0)
            rows.append((way, s))
            print(String(format: "%-6@ %.2fs", way as NSString, s))
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
    }
    for way in ["before", "cold", "warm"] {
        let v = rows.filter { $0.0 == way }.map(\.1)
        print(String(format: "%-6@ average %.2fs, best %.2fs, worst %.2fs", way as NSString, v.reduce(0, +) / Double(v.count), v.min()!, v.max()!))
    }
    WarmAgent.enhance.stop()
}

@MainActor private final class Got { var at: Date? }

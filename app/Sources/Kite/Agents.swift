import AppKit

// 5: the agent dock. Agents are folders in the repo's agents/ (persona.md + agent.json);
// runs are started by bin/kite, the one engine, which runs the user's own `claude -p`.
// Kite only reads the run folders it writes: status, result.md, events.jsonl.

// Where Kite's helper processes look for programs. Apps don't get the shell's PATH, so this names
// the user's own claude (native installer: ~/.local/bin; Homebrew; npm -g) and a python3 / uv.
enum Kite {
    // Where bin/kite, agents, mcp and voice live: the checkout a dev build came from, or inside the
    // app for a release build (Info.plist says "@bundle"), so Workshop runs on any Mac.
    static var root: String? {
        if let r = ProcessInfo.processInfo.environment["KITE_ROOT"], !r.isEmpty { return r }  // a build run from the build folder (--render)
        guard let r = (Bundle.main.object(forInfoDictionaryKey: "SantaRowRootPath") ?? Bundle.main.object(forInfoDictionaryKey: "KiteRootPath")) as? String
        else { return nil }
        guard r == "@bundle", let res = Bundle.main.resourcePath else { return r }
        return FileManager.default.fileExists(atPath: res + "/penpal") ? res + "/penpal" : res + "/kite"  // Penpal's own engine (#310)
    }
    // The engine's command, relative to root: bin/penpal inside Penpal (#310), bin/kite in a checkout and the other apps.
    static var cli: String {
        guard let r = root else { return "bin/kite" }
        return FileManager.default.fileExists(atPath: r + "/bin/penpal") ? "bin/penpal" : "bin/kite"
    }
    static let path = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
}

struct Agent: Identifiable, Hashable {
    let name: String
    let icon: String
    let summary: String
    let dir: URL
    var mission: Mission?  // set for mission agents (~/.kite/agents/mission-*/mission.json)
    var id: String { name }
    var title: String { mission?.title ?? name.capitalized }
}

// A subject in flight. Mirrors mission.json (bin/kite documents the fields).
// Penpal has no missions: a stand-in, so the shared agent list reads the same.
struct Mission: Hashable, Codable { var title: String }

struct Run: Identifiable, Hashable {
    let id: String
    let dir: URL
    let status: String  // working, done, error, died
    let question: String
    let seen: Bool
    let resume: String?     // the session this run continued, if it was a follow-up
    let sessionID: String?
    let kind: String?       // pull, report, check (a mission's work), brief, voice, telegram, else a chat turn
    var isHeartbeat: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("heartbeat").path) }
    var isReport: Bool { kind == "pull" || kind == "report" || kind == "check" }
    var isPull: Bool { isReport }  // older name
    // A team's satellite that made this pull, from the run's `satellite` file.
    var satellite: String? { (try? String(contentsOf: dir.appendingPathComponent("satellite"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    // The pull batch this run belongs to: a team's satellite pulls and the report over them share it.
    var batch: String? { (try? String(contentsOf: dir.appendingPathComponent("batch"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    // Your verdict on this report: "useful" or "not" (from the phone or the Mac), nil if unrated.
    var rating: String? { (try? String(contentsOf: dir.appendingPathComponent("rating"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    // What this run would have cost on the API (claude's own figure, in meta.json). The unit of fuel.
    private var meta: [String: Any]? {
        (try? Data(contentsOf: dir.appendingPathComponent("meta.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    var cost: Double? { meta?["total_cost_usd"] as? Double }
    // Every token the run went through: input (fresh, cache writes and cache reads) plus output.
    var tokens: Int? {
        guard let u = meta?["usage"] as? [String: Any] else { return nil }
        return ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].compactMap { u[$0] as? Int }.reduce(0, +)
    }
    var fuel: Fuel { Fuel(cost: cost ?? 0, tokens: tokens ?? 0) }
    // A watch's verdict for this check: same, changed or done.
    var watchStatus: String? { (try? String(contentsOf: dir.appendingPathComponent("watch"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }

    var waiting: Bool { status == "done" && !seen }
    var date: Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(id.prefix(15)))
    }
    // Which model answered, and how long it took: shown under each reply so a faster pick is felt.
    var model: String? {
        if let m = try? String(contentsOf: dir.appendingPathComponent("model"), encoding: .utf8) { return m.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent("events.jsonl")),
              let head = try? h.read(upToCount: 4000), let s = String(data: head, encoding: .utf8),
              let line = s.split(separator: "\n").first,
              let ev = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return ev["model"] as? String
    }
    var seconds: Double? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ms = m["duration_ms"] as? Double else { return nil }
        return ms / 1000
    }
    var image: URL? {
        let url = dir.appendingPathComponent("input.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    var mode: String? { (try? String(contentsOf: dir.appendingPathComponent("mode"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    // Voice turns: the recognizer that heard you and the language.
    var heard: String? { (try? String(contentsOf: dir.appendingPathComponent("heard"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    // Without the call's hang-up mark (#208), which is for Workshop, not for reading.
    var result: String? {
        (try? String(contentsOf: dir.appendingPathComponent("result.md"), encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
    }
    var hasSession: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("session_id").path) }

    // What the agent did, one line per tool call, from its stream-json log.
    var steps: [String] {
        guard let log = try? String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8) else { return [] }
        return log.split(separator: "\n").compactMap { line in
            guard let ev = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  ev["type"] as? String == "assistant",
                  let content = (ev["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { return nil }
            let calls = content.filter { $0["type"] as? String == "tool_use" }.map { call -> String in
                let input = call["input"] as? [String: Any] ?? [:]
                let name = call["name"] as? String ?? "tool"
                if name.hasPrefix("mcp__") {  // mcp__kite-tools__weather → "weather: Tokyo"
                    let tool = name.components(separatedBy: "__").last ?? name
                    let args = input.values.compactMap { $0 as? String }.filter { !$0.isEmpty }
                    return args.isEmpty ? tool : "\(tool): \(args.joined(separator: ", "))"
                }
                if let q = input["query"] as? String { return "Searched: \(q)" }
                if let u = input["url"] as? String { return "Read: \(u)" }
                return name
            }
            return calls.isEmpty ? nil : calls.joined(separator: "\n")
        }
    }

    // The run's log, for a look at what happened: each tool call and what came back (errors marked).
    struct LogEntry: Hashable { let call: String; let result: String; let error: Bool }
    var log: [LogEntry] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8) else { return [] }
        var calls: [(id: String, label: String)] = [], results: [String: (String, Bool)] = [:]
        for line in text.split(separator: "\n") {
            guard let ev = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let content = (ev["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for c in content {
                if c["type"] as? String == "tool_use", let id = c["id"] as? String {
                    let input = (c["input"] as? [String: Any]) ?? [:]
                    let args = input.values.compactMap { $0 as? String }.joined(separator: ", ")
                    let name = (c["name"] as? String ?? "tool").components(separatedBy: "__").last ?? "tool"
                    calls.append((id, args.isEmpty ? name : "\(name): \(args)"))
                } else if c["type"] as? String == "tool_result", let id = c["tool_use_id"] as? String {
                    let body: String
                    if let s = c["content"] as? String { body = s }
                    else if let parts = c["content"] as? [[String: Any]] { body = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                    else { body = "" }
                    results[id] = (String(body.prefix(1500)), c["is_error"] as? Bool ?? false)
                }
            }
        }
        return calls.map { LogEntry(call: $0.label, result: results[$0.id]?.0 ?? "(no answer)", error: results[$0.id]?.1 ?? false) }
    }

    var errorText: String? {
        (try? String(contentsOf: dir.appendingPathComponent("stderr.txt"), encoding: .utf8))
            .map { String($0.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published private(set) var agents: [Agent] = []
    @Published private(set) var runs: [String: [Run]] = [:]  // agent name → runs, newest first
    // The lens every agent talks in, from ~/.kite/mode (shared with bin/kite). nil = none.
    @Published private(set) var mode: String?
    // A screenshot waiting in an agent's message box, sent with the user's next message.
    @Published var pendingImage: (agent: String, png: Data)?
    @Published var newChatRequest = 0
    static let modeFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kite/mode")

    let root: URL
    // Your data: every agent's runs and your missions. The repo's agents/ holds only built-in definitions.
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kite/agents")
    static var builtin: URL {
        URL(fileURLWithPath: (Kite.root) ?? "").appendingPathComponent("agents")
    }
    private var timer: Timer?
    private var scheduler: Timer?
    private lazy var claudePath: String? = Self.findClaude()

    private init() {
        let path = Kite.root
        root = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
        refresh()
        // The app with agents re-reads their runs every 1.5 s; Penpal shows none (Guide me and Enhance read their
        // own run's folder), so every 10 s: each read is 11 to 27 ms on the main thread, small hitches (#258).
        timer = Timer.scheduledTimer(withTimeInterval: Flavor.current.has(.chat) ? 1.5 : 10, repeats: true) { _ in
            MainActor.assumeIsolated { AgentStore.shared.refresh() }
        }
        scheduler = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AgentStore.shared.runSchedules() }
        }
    }

    var anyWorking: Bool { runs.values.contains { $0.contains { $0.status == "working" } } }
    var anyWaiting: Bool { runs.values.contains { $0.contains(where: \.waiting) } }
    func working(_ agent: Agent) -> Bool { runs[agent.name]?.contains { $0.status == "working" } ?? false }
    func waiting(_ agent: Agent) -> Bool { runs[agent.name]?.contains(where: \.waiting) ?? false }
    // Unread results, counted like Messages' badge: per agent, and across all of them.
    // A team agent's pull isn't news on its own: its lead's report is.
    func unread(_ agent: Agent) -> Int { runs[agent.name]?.filter { $0.waiting && $0.satellite == nil }.count ?? 0 }
    // Everything the red dot counts, one row each, so the dot always ties out: its count is this
    // list's length, and the dock lists these rows so each one can be read or marked read.
    // Archived missions don't count, nor agents with no tile (Guide me): nowhere to read them.
    struct Unread: Identifiable { let agent: String; let title: String; let run: Run; var id: String { run.dir.path } }
    var unreadRuns: [Unread] {
        runs.filter { k, _ in !archived.contains { $0.name == k } && !tileless.contains(k) }
            .flatMap { name, rs in
                rs.filter { $0.waiting && $0.satellite == nil }.map { Unread(agent: name, title: agentNamed(name)?.title ?? name, run: $0) }
            }
            .sorted { $0.run.id > $1.run.id }  // newest first
    }
    var unreadTotal: Int { unreadRuns.count }
    func agentNamed(_ name: String) -> Agent? { (agents + allMissions + archived).first { $0.name == name } }

    func refresh() {
        let fm = FileManager.default
        var found: [Agent] = []
        var archivedFound: [Agent] = []
        var hidden: Set<String> = []
        var all: [String: [Run]] = [:]
        // Agents that ship with Kite (repo agents/) and yours (~/.kite/agents: missions); yours win on a name clash.
        let names = Set([Self.builtin, Self.home].flatMap { (try? fm.contentsOfDirectory(atPath: $0.path)) ?? [] })
        for name in names.sorted() {
            let dir = [Self.home, Self.builtin].map { $0.appendingPathComponent(name) }
                .first { fm.fileExists(atPath: $0.appendingPathComponent("persona.md").path) }
            guard let dir, let persona = try? String(contentsOf: dir.appendingPathComponent("persona.md"), encoding: .utf8) else { continue }
            let cfg = (try? Data(contentsOf: dir.appendingPathComponent("agent.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let summary = persona.split(separator: "\n").first { $0.hasPrefix("> ") }.map { String($0.dropFirst(2)) } ?? ""
            let mission = (try? Data(contentsOf: dir.appendingPathComponent("mission.json"))).flatMap { try? JSONDecoder().decode(Mission.self, from: $0) }
            all[name] = loadRuns(Self.home.appendingPathComponent("\(name)/runs"))  // runs are always yours
            if cfg["hidden"] as? Bool == true { hidden.insert(name); continue }  // e.g. the screen guide: runs tracked, no tile
            let agent = Agent(name: name, icon: cfg["icon"] as? String ?? "person.crop.circle", summary: summary, dir: dir, mission: mission)
            // Archived (like a Claude session): kept where it is, never runs, listed only when you ask.
            if mission != nil, fm.fileExists(atPath: dir.appendingPathComponent("archived").path) { archivedFound.append(agent); continue }
            found.append(agent)
        }
        if archivedFound != archived { archived = archivedFound }
        if hidden != tileless { tileless = hidden }
        let m = (try? String(contentsOf: Self.modeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (m?.isEmpty == false ? m : nil) != mode { mode = m?.isEmpty == false ? m : nil }
        let everyMission = found.filter { $0.mission != nil }
        if everyMission != allMissions { allMissions = everyMission }
        if !Labs.topics { found.removeAll { $0.mission != nil } }  // missions stay on disk, hidden from the dock
        if found != agents { agents = found }
        if all != runs {
            runs = all
        }
    }

    // A run that has finished doesn't change on its own, so it's read from disk once and kept.
    // Only working runs (and ones just marked seen) are read again; this used to re-read every
    // run of every agent each 1.5 s, the biggest idle cost Kite had.
    private var runCache: [String: Run] = [:]

    private func loadRuns(_ folder: URL) -> [Run] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted(by: >).compactMap { id in
            let dir = folder.appendingPathComponent(id)
            if let cached = runCache[dir.path], cached.status != "working" { return cached }
            let run = readRun(id: id, dir: dir)
            runCache[dir.path] = run
            return run
        }
    }

    private func readRun(id: String, dir: URL) -> Run? {
        let fm = FileManager.default
        do {
            func read(_ f: String) -> String? {
                (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let question = read("input.md") else { return nil }
            var status = read("status") ?? "working"
            if status == "working", let pid = read("pid").flatMap(Int32.init), kill(pid, 0) != 0 { status = "died" }
            return Run(id: id, dir: dir, status: status, question: question,
                       seen: fm.fileExists(atPath: dir.appendingPathComponent("seen").path),
                       resume: read("resume"), sessionID: read("session_id"), kind: read("kind"))
        }
    }


    func setMode(_ name: String?) {
        try? FileManager.default.createDirectory(at: Self.modeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ((name ?? "") + "\n").write(to: Self.modeFile, atomically: true, encoding: .utf8)
        mode = name
        Log.line("mode \(name ?? "none")")
    }

    // A screenshot for the side chat: it waits in Chat's message box until the user sends.
    func attach(_ png: Data) {
        guard let agent = agents.first(where: { $0.name == "chat" }) ?? agents.first else {
            return Log.line("no agent to take the screenshot")
        }
        pendingImage = (agent.name, png)
        newChatRequest += 1
        Log.line("screenshot waiting in \(agent.name)")
    }

    // The model for a kind of run, from Settings → Models: "chat", "agents" (missions) or "voice". Empty = your default.
    static func model(for purpose: String) -> String? {
        let m = UserDefaults.standard.string(forKey: "model.\(purpose)") ?? ""
        return m.isEmpty ? nil : m
    }
    private func modelArgs(_ purpose: String) -> [String] { Self.model(for: purpose).map { ["--model", $0] } ?? [] }

    // Voice and phone calls: Opus 5.5 at effort low unless a model is picked in Settings. Voice brain bench
    // (claude-kite bench/brain, 2026-10-03, 10 runs each): right 10/10 at every effort, about 0.75 s to the
    // first word, 2 s to start a session; Sonnet 5.5 low was as fast but got 2 in 10 time sums wrong.
    static let callModel = "claude-opus-5-5"
    static let callEffort = "low"
    // Effort for a kind of run (low … max), from UserDefaults "effort.<purpose>"; nil = Claude Code's default.
    static func effort(for purpose: String) -> String? {
        let e = UserDefaults.standard.string(forKey: "effort.\(purpose)") ?? ""
        return e.isEmpty ? nil : e
    }

    // ---------- Missions ----------

    var missions: [Agent] { Labs.topics ? agents.filter { $0.mission != nil } : [] }
    var topics: [Agent] { missions }  // older name
    // Every mission on disk, Labs or not (the other apps' missions; none in Penpal).
    @Published private(set) var allMissions: [Agent] = []
    @Published private(set) var archived: [Agent] = []  // archived missions: not run, shown in the sidebar on request
    @Published private(set) var tileless: Set<String> = []  // agents with runs but no tile (hidden), like Guide me
    var chatAgent: Agent? { agents.first { $0.name == "chat" } }

    // Scheduled pulls and checks, each minute, only while Kite is open. Never two at once per mission.
    private var lastCheck = Date.now
    private var lastRecord = Date.distantPast
    private func runSchedules() {
        let now = Date.now
        defer { lastCheck = now }
        // Every 15 min, record plan limits (/usage, zero tokens) and new requests into ~/.kite/usage,
        // so the history keeps growing while the Usage window is closed.
        if now.timeIntervalSince(lastRecord) >= 900, !Features.shared.jetpackPreview, Flavor.current.has(.usage), Flavor.isWorkshop || Features.on(.usage) {  // the app with the usage meter records it  // /usage runs claude: not in Jetpack
            lastRecord = now
            kite(["limits"]) { _ in AgentStore.shared.kite(["usage", "today"]) }
        }
    }

    private static func today(at hhmm: String) -> Date? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: .now)
    }

    // Any agent, hidden ones too: one run with an optional picture and background text,
    // or the next turn of `follow`. `started` gets the new run's id.
    func runAgent(_ name: String, _ text: String, png: Data? = nil, context: String? = nil, follow: String? = nil,
                  model: String? = nil, kind: String? = nil, started: @escaping @Sendable @MainActor (String?) -> Void) {
        let tmp = FileManager.default.temporaryDirectory
        var args = follow.map { ["follow", $0, text] } ?? ["run", name, text]
        if let model { args += ["--model", model] }
        if let kind { args += ["--kind", kind] }
        if let png {
            let f = tmp.appendingPathComponent("kite-shot-\(UUID().uuidString).png")
            if (try? png.write(to: f)) != nil { args += ["--image", f.path] }
        }
        if let context {
            let f = tmp.appendingPathComponent("kite-context-\(UUID().uuidString).md")
            if (try? context.write(to: f, atomically: true, encoding: .utf8)) != nil { args += ["--context", f.path] }
        }
        kite(args, started: started)
    }

    func run(_ id: String) -> Run? { runs.values.lazy.flatMap { $0 }.first { $0.id == id } }

    private func kite(_ args: [String], started: (@Sendable @MainActor (String?) -> Void)? = nil) {
        let task = Process()
        task.executableURL = root.appendingPathComponent(Kite.cli)
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        // Apps don't get the shell's PATH, so name the user's own claude and a python3.
        env["PATH"] = Kite.path
        if let claudePath { env["KITE_CLAUDE"] = claudePath }
        task.environment = env
        let err = Pipe()
        task.standardError = err
        let out = Pipe()
        task.standardOutput = out
        task.terminationHandler = { task in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // bin/kite prints "<agent>/<run id> working"
            let printed = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let runID = printed.split(separator: " ").first?.split(separator: "/").last.map(String.init)
            let status = task.terminationStatus
            Task { @MainActor in
                started?(status == 0 ? runID : nil)
                for flag in ["--image", "--context"] {  // temp files; bin/kite has copied them into the run
                    if let i = args.firstIndex(of: flag) { try? FileManager.default.removeItem(atPath: args[i + 1]) }
                }
                Log.line("helper \(args.first ?? "") exit=\(status)\(msg.isEmpty ? "" : ": " + msg.prefix(200))")
                AgentStore.shared.refresh()
            }
        }
        do { try task.run() } catch { Log.line("helper failed to start: \(error)") }
    }

    // The user's installed claude: common install spots first, then their login shell.
    private static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let spots = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
        if let hit = spots.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        shell.standardOutput = out
        try? shell.run()
        shell.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }
}

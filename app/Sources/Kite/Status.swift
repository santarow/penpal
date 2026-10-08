import AppKit
import SwiftUI

// Live status (#244, Jason: "this is like Apple's stickies app ... lets make a square widget to start this
// process underneath guide me"): a small floating note with one Claude session's steps, ticking to Done as
// the session works. Read from the session's own transcript (~/.claude/projects/…/<id>.jsonl), never from
// tables it writes in prose:
//   its task list, when it keeps one (TaskCreate / TaskUpdate, or TodoWrite in older Claude Code)
//   else what it does this turn: each tool call is a step, done when its result comes back
// The note says which, so a session with no task list is plainly shown as such.

struct StatusRow: Identifiable {
    enum State { case pending, working, stopped, done, failed }
    let id: String
    var title: String
    var state: State
    var started: Date?
    var ended: Date?
    var took: String? {
        guard let started else { return nil }
        let s = Int((ended ?? .now).timeIntervalSince(started))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

// The transcript, read as it grows: only the new lines each time, so a long session stays cheap.
// Used by one thread at a time: its first read off the main thread, then the main thread's timer (which
// waits for that first read, see StatusModel.ready).
final class StatusReader: @unchecked Sendable {
    let path: String
    private var offset: UInt64 = 0
    private var carry = Data()
    // Task list
    private(set) var tasks: [String: StatusRow] = [:]
    private(set) var taskOrder: [String] = []
    private var creating: [String: String] = [:]   // tool_use id → subject, until the result says its number
    private var todos: [StatusRow] = []            // TodoWrite's whole list, as last written
    // This turn's steps
    private(set) var steps: [StatusRow] = []
    private(set) var ask = ""
    private(set) var lastAt: Date?
    // Only read, and ISO8601DateFormatter is safe to parse with from any thread.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    init(path: String) { self.path = path }

    var hasTasks: Bool { !taskOrder.isEmpty || !todos.isEmpty }
    var taskRows: [StatusRow] { todos.isEmpty ? taskOrder.compactMap { tasks[$0] } : todos }

    // Reads what was added since last time. Returns whether anything was.
    @discardableResult func update() -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; carry = Data(); tasks = [:]; taskOrder = []; todos = []; steps = [] }  // rewritten
        guard size > offset else { return false }
        try? h.seek(toOffset: offset)
        var data = carry + ((try? h.readToEnd()) ?? Data())
        offset = size
        // Keep a half-written last line for next time.
        if let last = data.lastIndex(of: 0x0A) { carry = data[(last + 1)...]; data = data[..<last] } else { carry = data; return false }
        for line in data.split(separator: 0x0A) { take(Data(line)) }
        return true
    }

    private func take(_ line: Data) {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let at = (d["timestamp"] as? String).flatMap { Self.iso.date(from: $0) }
        if let at { lastAt = at }
        let type = d["type"] as? String
        let content = (d["message"] as? [String: Any])?["content"]
        if type == "user" {
            let blocks = content as? [[String: Any]] ?? []
            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            if results.isEmpty {
                // A new message from you: a new turn, its steps start over. (Not the app's own notes.)
                guard d["isMeta"] as? Bool != true, d["isSidechain"] as? Bool != true else { return }
                let text = (content as? String) ?? blocks.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
                guard !text.hasPrefix("<"), !text.isEmpty else { return }
                ask = String(text.prefix(140))
                steps = []
                return
            }
            let result = d["toolUseResult"] as? [String: Any]
            for r in results {
                let id = r["tool_use_id"] as? String ?? ""
                if let subject = creating.removeValue(forKey: id) {
                    let n = ((result?["task"] as? [String: Any])?["id"] as? String) ?? "\(taskOrder.count + 1)"
                    tasks[n] = StatusRow(id: n, title: subject, state: .pending)
                    taskOrder.append(n)
                }
                if let i = steps.firstIndex(where: { $0.id == id }) {
                    steps[i].state = r["is_error"] as? Bool == true ? .failed : .done
                    steps[i].ended = at
                }
            }
            return
        }
        guard type == "assistant", d["isSidechain"] as? Bool != true else { return }
        for b in content as? [[String: Any]] ?? [] where b["type"] as? String == "tool_use" {
            let name = b["name"] as? String ?? "", id = b["id"] as? String ?? "", input = b["input"] as? [String: Any] ?? [:]
            switch name {
            case "TaskCreate":
                creating[id] = input["subject"] as? String ?? "Task"
            case "TaskUpdate":
                let n = "\(input["taskId"] ?? "")"
                guard var t = tasks[n] else { continue }
                if let s = input["subject"] as? String { t.title = s }
                switch input["status"] as? String {
                case "in_progress": t.state = .working; t.started = t.started ?? at
                case "completed": t.state = .done; t.ended = at
                case "pending": t.state = .pending
                case "deleted": tasks[n] = nil; taskOrder.removeAll { $0 == n }; continue
                default: break
                }
                tasks[n] = t
            case "TodoWrite":
                let was = Dictionary(todos.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
                todos = (input["todos"] as? [[String: Any]] ?? []).enumerated().map { i, t in
                    let title = t["content"] as? String ?? "Step \(i + 1)"
                    var row = was[title] ?? StatusRow(id: "\(i)", title: title, state: .pending)
                    switch t["status"] as? String {
                    case "in_progress": row.state = .working; row.started = row.started ?? at
                    case "completed": row.state = .done; row.started = row.started ?? at; row.ended = row.ended ?? at
                    default: row.state = .pending
                    }
                    return row
                }
            default:
                steps.append(StatusRow(id: id, title: Self.describe(name, input), state: .working, started: at))
            }
        }
    }

    // A step in plain words: its own description when it gave one (Bash, agents), else the tool and its object.
    static func describe(_ name: String, _ input: [String: Any]) -> String {
        func base(_ k: String) -> String { ((input[k] as? String) ?? "").split(separator: "/").last.map(String.init) ?? "" }
        if let d = input["description"] as? String, !d.isEmpty { return d }
        switch name {
        case "Bash": return (input["command"] as? String).map { "Run " + String($0.prefix(60)) } ?? "Run a command"
        case "Read": return "Read \(base("file_path"))"
        case "Edit", "MultiEdit": return "Edit \(base("file_path"))"
        case "Write": return "Write \(base("file_path"))"
        case "Grep": return "Search for \((input["pattern"] as? String ?? "").prefix(40))"
        case "Glob": return "Find \((input["pattern"] as? String ?? "").prefix(40))"
        case "WebFetch": return "Read \((input["url"] as? String ?? "a web page").prefix(50))"
        case "WebSearch": return "Search the web: \((input["query"] as? String ?? "").prefix(40))"
        default:
            let short = name.hasPrefix("mcp__") ? String(name.split(separator: "__").last ?? Substring(name)) : name
            return short.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct StatusSession: Identifiable, Hashable {
    let id: String, title: String, path: String, end: String
}

@MainActor
final class StatusModel: ObservableObject {
    @Published var sessions: [StatusSession] = []
    @Published var session: StatusSession?
    @Published var rows: [StatusRow] = []
    @Published var tasks = false        // rows are its task list (else this turn's steps)
    @Published var ask = ""
    @Published var earlier = 0          // steps this turn not shown (only the last ones fit)
    @Published var tick = 0             // redraw durations
    private var reader: StatusReader?
    private var ready = false  // the first read is done: the timer may read more
    private var timer: Timer?
    static let shown = 12

    func watch(_ s: StatusSession) {
        session = s
        let r = StatusReader(path: s.path)
        reader = r
        rows = []; ask = ""; ready = false
        DispatchQueue.global(qos: .userInitiated).async {  // a long transcript's first read is off the main thread
            r.update()
            DispatchQueue.main.async { MainActor.assumeIsolated { if self.reader === r { self.ready = true; self.publish(r) } } }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let r = self.reader, self.ready else { return }
                if r.update() { self.publish(r) } else { self.tick += 1 }
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func publish(_ r: StatusReader) {
        tasks = r.hasTasks
        ask = r.ask
        var all = r.hasTasks ? r.taskRows : r.steps
        // A session quiet for 5 minutes isn't working any more: its open rows stopped when it went quiet.
        if let last = r.lastAt, Date.now.timeIntervalSince(last) > 300 {
            for i in all.indices where all[i].state == .working { all[i].state = .stopped; all[i].ended = last }
        }
        earlier = r.hasTasks ? 0 : max(0, all.count - Self.shown)
        rows = Array(all.suffix(r.hasTasks ? all.count : Self.shown))
    }

    // Your Claude Code sessions in the app, newest first, through bin/kite history (titles as the app shows them).
    func loadSessions(then: @escaping @MainActor () -> Void) {
        guard let root = Kite.root else { return then() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli)
        p.arguments = ["history", "40"]
        p.environment = Kite.engineEnv
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return then() }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let list = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []).compactMap { d -> StatusSession? in
                guard d["byClaude"] as? Bool != true, d["archived"] as? Bool != true, d["inApp"] as? Bool == true,
                      let id = d["id"] as? String, let path = d["path"] as? String else { return nil }
                let title = (d["appTitle"] as? String) ?? (d["title"] as? String) ?? String(id.prefix(8))
                return StatusSession(id: id, title: title, path: path, end: d["end"] as? String ?? "")
            }.sorted { $0.end > $1.end }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.sessions = list; then() } }
        }
    }

    // The session in Claude's front window: its title is in the window's header. Else the newest one.
    func frontSession() -> StatusSession? {
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else { return sessions.first }
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
        let app = AXUIElementCreateApplication(claude.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let w = attr(app, "AXFocusedWindow") ?? (attr(app, "AXWindows") as? [AXUIElement])?.first else { return sessions.first }
        let titles = Set(sessions.map(\.title))
        var queue = [w as! AXUIElement], seen = 0
        while !queue.isEmpty, seen < 2500 {
            let e = queue.removeFirst(); seen += 1
            if attr(e, "AXRole") as? String == "AXStaticText", let v = attr(e, "AXValue") as? String, titles.contains(v),
               let p = attr(e, "AXPosition") {
                var pt = CGPoint.zero; AXValueGetValue(p as! AXValue, .cgPoint, &pt)
                var top = CGPoint.zero
                if let wp = attr(w as! AXUIElement, "AXPosition") { AXValueGetValue(wp as! AXValue, .cgPoint, &top) }
                if pt.y - top.y < 70 && pt.x - top.x > 250 { return sessions.first { $0.title == v } }  // the header, not the sidebar
            }
            queue += attr(e, "AXChildren") as? [AXUIElement] ?? []
        }
        return sessions.first
    }
}

struct StatusView: View {
    @ObservedObject var model: StatusModel
    static let paper = Color(red: 1.0, green: 0.96, blue: 0.62)   // Stickies yellow
    static let ink = Color(red: 0.2, green: 0.17, blue: 0.05)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(model.sessions) { s in Button(s.title) { model.watch(s) } }
            } label: {
                Text(model.session?.title ?? "Pick a session").font(.headline).foregroundStyle(Self.ink).lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
            if !model.ask.isEmpty {
                Text(model.ask).font(.caption).foregroundStyle(Self.ink.opacity(0.65)).lineLimit(2)
            }
            Divider().overlay(Self.ink.opacity(0.2))
            HStack {
                Text(model.tasks ? "Task" : "Step").font(.caption.weight(.semibold))
                Spacer()
                Text("Status").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Self.ink.opacity(0.7))
            if model.earlier > 0 {
                Text("\(model.earlier) earlier steps done").font(.caption).foregroundStyle(Self.ink.opacity(0.55))
            }
            if model.rows.isEmpty {
                Text(model.session == nil ? "No Claude Code session found." : "Nothing yet this turn.")
                    .font(.callout).foregroundStyle(Self.ink.opacity(0.6))
            }
            ForEach(model.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    mark(row.state).frame(width: 22, alignment: .leading)
                    Text(row.title).font(.callout)
                        .strikethrough(row.state == .done, color: Self.ink.opacity(0.5))
                        .foregroundStyle(row.state == .done ? Self.ink.opacity(0.5) : Self.ink)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Text(label(row)).font(.caption.monospacedDigit()).foregroundStyle(Self.ink.opacity(0.6))
                }
            }
            Text(model.tasks ? "Its task list, live." : "No task list in this session: these are its steps this turn, live.")
                .font(.caption2).foregroundStyle(Self.ink.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(Self.paper)
        .environment(\.colorScheme, .light)  // a sticky is yellow paper in both looks
        .id(model.tick)
    }

    @ViewBuilder private func mark(_ s: StatusRow.State) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(Self.ink.opacity(0.4))
        case .working: ThinkingDots()
        case .stopped: Image(systemName: "pause.circle").foregroundStyle(Self.ink.opacity(0.5))
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
    private func label(_ r: StatusRow) -> String {
        switch r.state {
        case .pending: return "to do"
        case .working: return "working" + (r.took.map { " · \($0)" } ?? "")
        case .stopped: return "stopped" + (r.took.map { " · \($0)" } ?? "")
        case .done: return "done" + (r.took.map { " · \($0)" } ?? "")
        case .failed: return "failed" + (r.took.map { " · \($0)" } ?? "")
        }
    }
}

// More than one can be open: each tile click opens a new note.
@MainActor
enum StatusWindows {
    private static var open: [NSPanel: StatusModel] = [:]

    static func newSticky() {
        let model = StatusModel()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 240), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Live status"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = NSColor(red: 1.0, green: 0.96, blue: 0.62, alpha: 1)
        let host = NSHostingView(rootView: StatusView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        let screen = NSScreen.main?.visibleFrame ?? .zero
        p.setFrameTopLeftPoint(NSPoint(x: screen.minX + 40 + CGFloat(open.count * 24), y: screen.maxY - 40 - CGFloat(open.count * 24)))
        open[p] = model
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { open[p]?.stop(); open[p] = nil }
        }
        p.orderFrontRegardless()
        model.loadSessions {
            if let s = model.frontSession() { model.watch(s); p.title = "Live status · \(s.title)" }
        }
        Log.line("live status: opened (\(open.count) open)")
    }

    // --render-status <transcript.jsonl> <out.png>: one session's note drawn to a picture, for checking.
    static func render(transcript: String, to out: String) {
        _ = NSApplication.shared
        let model = StatusModel()
        let r = StatusReader(path: transcript)
        r.update()
        model.session = StatusSession(id: "", title: URL(fileURLWithPath: transcript).deletingPathExtension().lastPathComponent.prefix(8) + "…", path: transcript, end: "")
        model.publish(r)
        let host = NSHostingView(rootView: StatusView(model: model))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bmp)
            try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        print("\(r.hasTasks ? "task list" : "steps this turn"): \(model.rows.count) rows, \(model.rows.filter { $0.state == .done }.count) done; ask: \(r.ask.prefix(60))")
    }
}

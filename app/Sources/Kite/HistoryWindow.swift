import AppKit
import SwiftUI

// History: what Claude keeps on this Mac but doesn't show. Every Claude Code session (the Code tab
// and the terminal), each with what you asked, how it answered, the tokens it took and every
// image you pasted. Read-only, from ~/.claude/projects, through `bin/kite history` and
// `bin/kite session`. Kite's own agent runs and throwaway claude -p runs are left out.
struct HistorySession: Decodable, Identifiable, Hashable {
    struct Tokens: Decodable, Hashable { let `in`: Int; let out: Int; let cache_write: Int; let cache_read: Int }
    let id: String, path: String, project: String, title: String, first: String
    let prompts: Int, images: Int, requests: Int
    let tokens: Tokens
    let start: String?, end: String?
    let headless: Bool?
    let archived: Bool?     // archived in the Claude app
    let inApp: Bool?        // the Claude app has it (not only started in Terminal)
    let appTitle: String?   // its title in the Claude app, e.g. "Building (fork)"
    let parts: [String]?    // its transcript pieces, oldest first, when the app split it into several
    let account: String?    // the Claude account whose sidebar has it (the app keeps one per account)
    let here: Bool?         // in the signed-in account's sidebar
    let fork: Bool?         // a fork of another session
    let byClaude: Bool?     // Claude started it (a task handed to a new session): no prompt of yours
    var name: String { appTitle ?? title }
    // The repository, like the Claude app's Folder groups: a worktree counts as its repository.
    var folder: String {
        let repo = project.components(separatedBy: "/.claude/worktrees/").first ?? project
        return URL(fileURLWithPath: repo).lastPathComponent
    }
    var date: Date? { end.flatMap { ISO8601DateFormatter.frac.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
    var projectName: String { URL(fileURLWithPath: project).lastPathComponent }
}

struct HistoryTurn: Decodable, Identifiable, Hashable {
    let at: String?, prompt: String, answer: String
    let images: [String]
    let tools: Int, out: Int, `in`: Int
    let also: [String]?     // what you sent while Claude was still working on this turn
    let working: Bool?      // no answer yet: Claude was mid-turn when this was read
    let uuid: String?       // the turn's last message in the transcript: where a fork from here starts
    let byClaude: Bool?     // the opening instructions of a session Claude started, not your prompt
    var shownAnswer: String {
        if !answer.isEmpty { return answer }
        if working == true { return "_Claude is still working on this (\(tools) tool calls so far). Open the session again for the answer._" }
        return prompt.hasPrefix("[Request interrupted") ? "_Stopped._" : "_No written answer: this turn only used tools._"
    }
    var id: String { (at ?? "") + prompt.prefix(40) }
    var date: Date? { at.flatMap { ISO8601DateFormatter.frac.date(from: $0) } }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let frac: ISO8601DateFormatter = {  // read-only after setup
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// A pinned turn keeps its own copy of the prompt and answer, so it stays even if the session
// file is moved or trimmed. Pins live in ~/.kite/history/pins.json, Kite's file, not Claude's.
struct PinnedTurn: Codable, Identifiable, Hashable {
    let session: String, sessionTitle: String, at: String?, prompt: String, answer: String
    var id: String { session + "|" + (at ?? "") + prompt.prefix(40) }
}

// Your own folders, like Notes: sessions dragged or moved into one leave the list below and sit
// in it. Kite's file (~/.kite/history/folders.json), not the Claude app's groups.
struct HistoryFolder: Codable, Identifiable, Hashable { let id: String; var name: String }

@MainActor
final class HistoryModel: ObservableObject {
    @Published var folders: [HistoryFolder] = []
    @Published var inFolder: [String: String] = [:]    // session id → folder id
    @Published var dropTarget: String?                   // the folder a drag is over
    @Published var collapsed = Set(UserDefaults.standard.stringArray(forKey: "history.collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "history.collapsed") }
    }
    private static let foldersFile = Kite.read("history/folders.json")
    private struct Folders: Codable { var folders: [HistoryFolder]; var sessions: [String: String] }
    func loadFolders() {
        guard let d = try? Data(contentsOf: Self.foldersFile), let f = try? JSONDecoder().decode(Folders.self, from: d) else { return }
        folders = f.folders; inFolder = f.sessions
    }
    private func saveFolders() {
        try? FileManager.default.createDirectory(at: Self.foldersFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(Folders(folders: folders, sessions: inFolder)) { try? d.write(to: Self.foldersFile) }
    }
    @discardableResult func newFolder(_ name: String) -> String {
        let f = HistoryFolder(id: UUID().uuidString, name: name)
        folders.append(f); saveFolders(); return f.id
    }
    func rename(_ f: HistoryFolder, to name: String) {
        guard let i = folders.firstIndex(of: f) else { return }
        folders[i].name = name; saveFolders()
    }
    // The sessions go back to the list; nothing else is touched.
    func delete(_ f: HistoryFolder) {
        folders.removeAll { $0.id == f.id }
        inFolder = inFolder.filter { $0.value != f.id }
        saveFolders()
    }
    func move(_ ids: [String], to folder: String?) {
        for id in ids { if let folder { inFolder[id] = folder } else { inFolder[id] = nil } }
        if let folder { collapsed.remove(folder) }
        saveFolders()
    }
    func folder(of s: HistorySession) -> HistoryFolder? { inFolder[s.id].flatMap { id in folders.first { $0.id == id } } }
    func sessions(in f: HistoryFolder) -> [HistorySession] {
        var list = sessions.filter { inFolder[$0.id] == f.id && !isPinned($0) && matches($0) && passes($0) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if sort == "alpha" { list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        return list
    }
    @Published var pinnedSessions: [String] = []   // session ids, most recently pinned first
    @Published var pinnedTurns: [PinnedTurn] = []
    @Published var showPinnedTurns = false         // the "Pinned answers" view across sessions
    @Published var columns: NavigationSplitViewVisibility = .all  // .doubleColumn hides the sessions list
    private static let pinsFile = Kite.read("history/pins.json")
    private struct Pins: Codable { var sessions: [String]; var turns: [PinnedTurn] }

    func loadPins() {
        guard let d = try? Data(contentsOf: Self.pinsFile), let p = try? JSONDecoder().decode(Pins.self, from: d) else { return }
        pinnedSessions = p.sessions; pinnedTurns = p.turns
    }
    private func savePins() {
        try? FileManager.default.createDirectory(at: Self.pinsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Pins(sessions: pinnedSessions, turns: pinnedTurns)) { try? d.write(to: Self.pinsFile) }
    }
    func isPinned(_ s: HistorySession) -> Bool { pinnedSessions.contains(s.id) }
    func togglePin(_ s: HistorySession) {
        if let i = pinnedSessions.firstIndex(of: s.id) { pinnedSessions.remove(at: i) } else { pinnedSessions.insert(s.id, at: 0) }
        savePins()
    }
    func pin(for t: HistoryTurn) -> PinnedTurn? {
        guard let s = selected else { return nil }
        return PinnedTurn(session: s.id, sessionTitle: s.title, at: t.at, prompt: t.prompt, answer: t.answer)
    }
    func isPinned(_ t: HistoryTurn) -> Bool { pin(for: t).map { p in pinnedTurns.contains { $0.id == p.id } } ?? false }
    func togglePin(_ t: HistoryTurn) {
        guard let p = pin(for: t) else { return }
        if let i = pinnedTurns.firstIndex(where: { $0.id == p.id }) { pinnedTurns.remove(at: i) } else { pinnedTurns.insert(p, at: 0) }
        savePins()
    }
    func unpin(_ p: PinnedTurn) { pinnedTurns.removeAll { $0.id == p.id }; savePins() }
    @Published var pinnedPick: PinnedTurn?

    @Published var sessions: [HistorySession] = []
    @Published var selected: HistorySession? { didSet { loadTurns() } }
    @Published var turns: [HistoryTurn] = []
    @Published var turn: HistoryTurn?
    @Published var turnTag: String?  // which row was clicked: a pinned turn is in the list twice
    // Find in this session (⌘F): the turns whose words match, and which one is showing.
    @Published var find = "" { didSet { findIndex = -1; if !find.isEmpty { nextMatch(1) } } }
    @Published var findIndex = -1
    var matches: [HistoryTurn] {
        guard !find.isEmpty else { return [] }
        return turns.filter { t in
            t.prompt.localizedCaseInsensitiveContains(find) || t.answer.localizedCaseInsensitiveContains(find)
                || (t.also ?? []).contains { $0.localizedCaseInsensitiveContains(find) }
        }
    }
    // The next (1) or previous (-1) match, shown and selected; wraps around.
    func nextMatch(_ step: Int) {
        let m = matches
        guard !m.isEmpty else { findIndex = -1; return }
        findIndex = ((findIndex < 0 && step < 0 ? 0 : findIndex) + step + m.count) % m.count
        turn = m[findIndex]; turnTag = m[findIndex].id
    }
    @Published var tab = 0  // 0 turns, 1 images
    @Published var pickedImage: String?  // the image clicked in the Images tab (it stays there)
    @Published var search = ""
    @Published var showRuns = false
    // Like the Claude app's archive: archived sessions stay out of the list unless asked for.
    @Published var status = UserDefaults.standard.string(forKey: "history.status") ?? "active" { didSet { UserDefaults.standard.set(status, forKey: "history.status") } }
    // Sessions the Claude app has no record of (deleted there, lost, or started in Terminal): hidden,
    // so the list matches the app, unless asked for.
    @Published var notInApp = UserDefaults.standard.bool(forKey: "history.notInApp") { didSet { UserDefaults.standard.set(notInApp, forKey: "history.notInApp") } }
    // Sessions the Claude app files under another account than the one signed in (its sidebar is per
    // account). Only counted here; bringing them back is PurpleRestore's job.
    @Published var otherAccount = 0
    var filtered: Bool { status != "active" || notInApp }
    // Grouped and sorted the way the Claude app's Code sidebar is, unless picked here.
    @Published var groupBy = UserDefaults.standard.string(forKey: "history.group") ?? "app" { didSet { UserDefaults.standard.set(groupBy, forKey: "history.group") } }
    @Published var sortBy = UserDefaults.standard.string(forKey: "history.sort") ?? "app" { didSet { UserDefaults.standard.set(sortBy, forKey: "history.sort") } }
    // The Claude app's last known choice, kept in case its store can't be read next time.
    @Published var appGroup = UserDefaults.standard.string(forKey: "history.appGroup") { didSet { UserDefaults.standard.set(appGroup, forKey: "history.appGroup") } }
    @Published var appSort = UserDefaults.standard.string(forKey: "history.appSort") { didSet { UserDefaults.standard.set(appSort, forKey: "history.appSort") } }
    var group: String {
        let g = groupBy == "app" ? appGroup ?? "date" : groupBy
        return ["date", "project", "none"].contains(g) ? g : g == "custom" ? "none" : "date"
    }
    var sort: String { let o = sortBy == "app" ? appSort ?? "recency" : sortBy; return o == "alpha" ? o : "recency" }
    var groups: [(name: String, sessions: [HistorySession])] {
        // Newest first by the last message (a file's time moves when the Claude app only touches it).
        var list = shown.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let newest = list
        if sort == "alpha" { list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        let key: (HistorySession) -> String
        switch group {
        case "project": key = { $0.folder }
        case "date": key = { Self.bucket($0.date) }
        default: return [("\(list.count) sessions", list)]
        }
        // Groups in order of their newest session: Today before Yesterday, the busiest folder on top.
        var order: [String] = [], by: [String: [HistorySession]] = [:]
        for s in newest where by[key(s)] == nil { order.append(key(s)); by[key(s)] = [] }
        for s in list { by[key(s), default: []].append(s) }
        return order.map { ($0, by[$0] ?? []) }
    }
    static func bucket(_ d: Date?) -> String {
        guard let d else { return "Older" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "Previous 7 days" }
        if days < 30 { return "Previous 30 days" }
        return d.formatted(.dateTime.month(.wide).year())
    }
    @Published var loading = false

    private var root: URL { URL(fileURLWithPath: (Kite.root) ?? "") }

    var shown: [HistorySession] {
        sessions.filter { !isPinned($0) && folder(of: $0) == nil && (showRuns || $0.headless != true) && matches($0) && passes($0) }
    }
    var pinnedShown: [HistorySession] {
        pinnedSessions.compactMap { id in sessions.first { $0.id == id } }.filter(matches)
    }
    private func passes(_ s: HistorySession) -> Bool {
        let archived = s.archived == true
        if status == "active" && archived || status == "archived" && !archived { return false }
        return notInApp || s.inApp != false
    }
    private func matches(_ s: HistorySession) -> Bool {
        search.isEmpty || s.name.localizedCaseInsensitiveContains(search) || s.first.localizedCaseInsensitiveContains(search)
    }
    // A session's pinned turns: shortcuts on top. Every turn also stays in its place in time.
    var pinnedHere: [HistoryTurn] { turns.filter(isPinned) }

    func load() {
        loadPins()
        loadFolders()
        loading = true
        run(["app-sidebar"]) { data in
            let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let g = d?["group"] as? String { self.appGroup = g }
            if let o = d?["sort"] as? String { self.appSort = o }
        }
        run(["app-accounts"]) { data in
            self.otherAccount = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["other"] as? Int ?? 0
        }
        run(["history", "150"]) { data in
            self.sessions = (try? JSONDecoder().decode([HistorySession].self, from: data)) ?? []
            self.loading = false
            if self.selected == nil { self.selected = self.pinnedShown.first ?? self.shown.first }
        }
    }

    private func loadTurns() {
        guard let s = selected else { turns = []; return }
        turns = []; turn = nil
        run(["session"] + (s.parts ?? [s.path])) { data in
            guard self.selected?.id == s.id else { return }
            self.turns = ((try? JSONDecoder().decode([HistoryTurn].self, from: data)) ?? []).reversed()  // newest first
            self.turn = self.turns.first
        }
    }

    private func run(_ args: [String], done: @escaping @MainActor (Data) -> Void) {
        let task = Process()
        task.executableURL = root.appendingPathComponent(Kite.cli)
        task.arguments = args
        var env = Kite.engineEnv
        task.environment = env
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return }
        // Read while it runs: the output is bigger than a pipe holds (64 KB), so reading only after it
        // exits would leave both sides waiting on each other.
        DispatchQueue.global(qos: .userInitiated).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            Task { @MainActor in done(data) }
        }
    }
}

@MainActor
enum HistoryWindow {
    private static var window: NSWindow?
    private static let model = HistoryModel()

    static func toggle() {
        if let w = window, w.isVisible, w.isKeyWindow, NSApp.isActive { return w.performClose(nil) }
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Claude History"
            let host = NSHostingView(rootView: HistoryView(model: model))
            host.sizingOptions = [.minSize]
            w.contentView = host
            // Show or hide the sessions list, like Notes: a button right after the window's
            // buttons, in the title bar, where it stays put whether the list is open or not.
            let acc = NSTitlebarAccessoryViewController()
            acc.layoutAttribute = .leading
            let button = NSHostingView(rootView: SessionsToggle(model: model))
            button.frame = NSRect(x: 0, y: 0, width: 40, height: 28)
            acc.view = button
            w.addTitlebarAccessoryViewController(acc)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            return w
        }()
        model.load()
        // Opens with the sessions list showing, unless Settings → General says otherwise; set after
        // the window is up, because a split view sized while offscreen can fold its sidebar away.
        if !w.isVisible {
            let show = UserDefaults.standard.object(forKey: "history.sessionsOpen") as? Bool ?? true
            DispatchQueue.main.async { model.columns = show ? .all : .doubleColumn }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @FocusState private var finding: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columns) {
            sessions.frame(minWidth: 260, idealWidth: 290)
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 380)
                .background(Palette.background)
                .toolbar(removing: .sidebarToggle)
        } content: {
            middle.navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { FillButton() } }
        .frame(minWidth: 900, minHeight: 500)
    }

    // MARK: sessions

    private var sessions: some View {
        VStack(spacing: 0) {
            TextField("Search sessions", text: $model.search).textFieldStyle(.roundedBorder).padding(10)
            List(selection: Binding(get: { model.showPinnedTurns ? "pinned-turns" : model.selected?.id },
                                    set: { id in
                                        if id == "pinned-turns" { model.showPinnedTurns = true; model.pinnedPick = model.pinnedTurns.first; return }
                                        model.showPinnedTurns = false
                                        model.selected = model.sessions.first { $0.id == id }
                                    })) {
                if !model.pinnedTurns.isEmpty || !model.pinnedShown.isEmpty {
                    Section("Pinned") {
                        if !model.pinnedTurns.isEmpty {
                            HStack(spacing: 8) {
                                IconTile(symbol: "pin.fill", color: .red, size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Pinned answers").lineLimit(1)
                                    Text("\(model.pinnedTurns.count) from all sessions").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag("pinned-turns")
                        }
                        ForEach(model.pinnedShown) { s in sessionRow(s, pinned: true) }
                    }
                }
                ForEach(model.folders) { f in
                    Section(isExpanded: Binding(get: { !model.collapsed.contains(f.id) },
                                                set: { open in if open { model.collapsed.remove(f.id) } else { model.collapsed.insert(f.id) } })) {
                        let inside = model.sessions(in: f)
                        if inside.isEmpty {
                            Text("Drag sessions here").font(.caption).foregroundStyle(.secondary)
                                .selectionDisabled()
                                .dropDestination(for: String.self) { ids, _ in model.move(ids, to: f.id); return true }
                        }
                        ForEach(inside) { s in
                            sessionRow(s, pinned: false)
                                .dropDestination(for: String.self) { ids, _ in model.move(ids, to: f.id); return true }
                        }
                    } header: {
                        FolderHeader(model: model, folder: f)
                    }
                }
                if model.loading {
                    Section("Reading…") {}
                } else {
                    ForEach(model.groups, id: \.name) { g in
                        Section {
                            ForEach(g.sessions) { s in sessionRow(s, pinned: false) }
                        } header: {
                            // Dropping a session here takes it out of its folder.
                            Text(g.name).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                .dropDestination(for: String.self) { ids, _ in model.move(ids, to: nil); return true }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                if model.otherAccount > 0 {
                    // Read only: a count and a way to PurpleRestore, which does the bringing back.
                    HStack(spacing: 6) {
                        Image(systemName: "person.2").foregroundStyle(.secondary)
                        Text("\(model.otherAccount) sessions in another account").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open PurpleRestore") { PurpleRestore.open() }.buttonStyle(.link).font(.caption)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .help("The Claude app keeps one sidebar per account, so sessions from an account you switched away from stop showing there. Their transcripts are still on this Mac. PurpleRestore can bring them back")
                    Divider()
                }
                HStack {
                    Menu {
                        Picker("Status", selection: $model.status) {
                            Text("Active").tag("active"); Text("Archived").tag("archived"); Text("All").tag("all")
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Picker("Group by", selection: $model.groupBy) {
                            Text("Same as the Claude app").tag("app")
                            Divider()
                            Text("Date").tag("date"); Text("Folder").tag("project"); Text("None").tag("none")
                        }
                        Picker("Sort by", selection: $model.sortBy) {
                            Text("Same as the Claude app").tag("app")
                            Divider()
                            Text("Recent").tag("recency"); Text("Name").tag("alpha")
                        }
                        Toggle("Not in the Claude app", isOn: $model.notInApp)
                            .help("Sessions the Claude app has no record of: deleted there, or started in Terminal. Their files are still on disk")
                        Divider()
                        Button("Clear filters") { model.status = "active"; model.notInApp = false; model.groupBy = "app"; model.sortBy = "app" }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle" + (model.filtered ? ".fill" : ""))
                            .foregroundStyle(model.filtered ? Color.accentColor : .secondary)
                    }
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                    .help("Filter: active or archived sessions (archived in the Claude app), and ones not in the Claude app")
                    Spacer()
                    Button { HistoryModel.ask("New Folder", name: "New Folder").map { model.newFolder($0) } } label: {
                        Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
                    }
                    .help("New folder. Drag sessions into it, or right-click a session → Move to Folder")
                }
                .buttonStyle(.plain).font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .background(.bar)  // on the current SDK the list scrolls under this footer; it covers what's beneath (#273)
            }
        }
    }

    private func sessionRow(_ s: HistorySession, pinned: Bool) -> some View {
        HStack(spacing: 8) {
            // Not in the Claude app: a gray tile, so it's told apart.
            IconTile(symbol: s.inApp == false ? "doc.text.fill" : "text.bubble.fill", color: s.inApp == false ? .gray : .indigo, size: 24)
                .help(s.inApp == false ? "Not in the Claude app (deleted there, or started in Terminal). The file is still on disk" : "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(s.name).lineLimit(1)
                    if s.fork == true { Pill(text: "fork") }
                    if s.archived == true && model.status != "active" { Pill(text: "archived") }
                }
                Text("\(s.projectName) · " + (s.byClaude == true ? "started by Claude" : "\(s.prompts) prompts") + (s.images > 0 ? " · \(s.images) images" : "")
                     + (s.date.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            PinMark(on: pinned)
        }
        .tag(s.id)
        .draggable(s.id)
        .contextMenu {
            Button(pinned ? "Unpin session" : "Pin session") { model.togglePin(s) }
            Menu("Move to Folder") {
                ForEach(model.folders) { f in
                    Button(f.name) { model.move([s.id], to: f.id) }.disabled(model.folder(of: s) == f)
                }
                if !model.folders.isEmpty { Divider() }
                Button("New Folder…") {
                    if let name = HistoryModel.ask("New Folder", name: "New Folder") { model.move([s.id], to: model.newFolder(name)) }
                }
            }
            if model.folder(of: s) != nil { Button("Remove from Folder") { model.move([s.id], to: nil) } }
            Divider()
            SessionActions(session: s)
        }
    }

    private func turnRow(_ t: HistoryTurn, pinned: Bool, tag: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Like a flag in Mail: the pin sits in its own column at the end, so the text of pinned
            // and unpinned turns starts in the same place.
            HStack(alignment: .top, spacing: 6) {
                Text((t.byClaude == true ? "Started by Claude: " : "") + (t.prompt.isEmpty ? "(an image)" : t.prompt)).lineLimit(2)
                Spacer(minLength: 4)
                PinMark(on: pinned).padding(.top, 2)
            }
            HStack(spacing: 6) {
                if let d = t.date { Text(d.formatted(date: .abbreviated, time: .shortened)) }
                if !t.images.isEmpty { Label("\(t.images.count)", systemImage: "photo") }
                if t.tools > 0 { Label("\(t.tools)", systemImage: "wrench.and.screwdriver") }
                Text("\(Self.k(t.out)) out")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .tag(tag ?? t.id)
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin this prompt and answer") { model.togglePin(t) }
            if let s = model.selected { Divider(); SessionActions(session: s) }
        }
    }

    // MARK: a session's turns, or its images

    private var middle: some View {
        VStack(spacing: 0) {
            if model.showPinnedTurns {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pinned answers").font(.headline)
                    Text("Your pinned prompts and answers, newest pin first. Each keeps its own copy.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
                List(selection: Binding(get: { model.pinnedPick?.id }, set: { id in model.pinnedPick = model.pinnedTurns.first { $0.id == id } })) {
                    ForEach(model.pinnedTurns) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.prompt.isEmpty ? "(an image)" : p.prompt).lineLimit(2)
                            Text(p.sessionTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(p.id)
                        .contextMenu { Button("Unpin") { model.unpin(p) } }
                    }
                }
            } else if let s = model.selected {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(s.name).font(.headline).lineLimit(2)
                        Spacer()
                        Button { model.togglePin(s) } label: { Image(systemName: model.isPinned(s) ? "pin.fill" : "pin") }
                            .buttonStyle(.borderless).help(model.isPinned(s) ? "Unpin this session" : "Pin this session to the top")
                    }
                    Text(s.project).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    tokenLine(s)
                    Picker("", selection: $model.tab) {
                        Text("Turns · \(s.prompts)").tag(0)
                        Text("Images · \(s.images)").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                .padding(12)
                Divider()
                if model.tab == 0 {
                    findBar
                    // Pinned turns appear twice: as a shortcut on top ("pin:" tags), and in their place below.
                    ScrollViewReader { proxy in
                    List(selection: Binding<String?>(get: {
                        guard let t = model.turn else { return nil }
                        return model.turnTag == "pin:" + t.id ? model.turnTag : t.id
                    }, set: { id in
                        let key = id.map { $0.hasPrefix("pin:") ? String($0.dropFirst(4)) : $0 }
                        model.turnTag = id
                        model.turn = model.turns.first { $0.id == key }
                    })) {
                        if !model.pinnedHere.isEmpty {
                            Section("Pinned") { ForEach(model.pinnedHere) { turnRow($0, pinned: true, tag: "pin:" + $0.id) } }
                        }
                        Section(model.pinnedHere.isEmpty ? "" : "All turns") { ForEach(model.turns) { turnRow($0, pinned: model.isPinned($0)).id($0.id) } }
                    }
                    // Back from the Images tab: the turn you picked there, in view.
                    .onAppear { if let t = model.turn { DispatchQueue.main.async { proxy.scrollTo(t.id, anchor: .center) } } }
                    // Find: each match is brought into view.
                    .onChange(of: model.findIndex) { _, _ in
                        if let t = model.turn, !model.find.isEmpty { withAnimation { proxy.scrollTo(t.id, anchor: .center) } }
                    }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                            ForEach(model.turns.flatMap { t in t.images.map { (t, $0) } }, id: \.1) { t, path in
                                // The outline first, at once; the turn (a long answer to lay out) right after.
                                Thumb(path: path) {
                                    model.pickedImage = path
                                    DispatchQueue.main.async { model.turn = t; model.turnTag = t.id }
                                }
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: model.pickedImage == path ? 3 : 0))
                                    .help(t.prompt.prefix(120) + "")
                            }
                        }
                        .padding(10)
                    }
                }
            } else {
                Text("Pick a session").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // ⌘F: find in this session; Return or ⌘G for the next match, ⇧⌘G for the one before.
    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in this session", text: $model.find)
                .textFieldStyle(.plain).focused($finding)
                .onSubmit { model.nextMatch(1) }
            if !model.find.isEmpty {
                let n = model.matches.count
                Text(n == 0 ? "None" : "\(max(model.findIndex, 0) + 1) of \(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { model.nextMatch(-1) } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(n == 0).help("Previous match (⇧⌘G)")
                Button { model.nextMatch(1) } label: { Image(systemName: "chevron.down") }
                    .keyboardShortcut("g", modifiers: .command).disabled(n == 0).help("Next match (⌘G)")
                Button { model.find = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .help("Clear")
            }
            Button("") { finding = true }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    private func tokenLine(_ s: HistorySession) -> some View {
        let t = s.tokens
        return HStack(spacing: 10) {
            Label("\(s.requests) requests", systemImage: "arrow.left.arrow.right")
            Label("\(Self.k(t.out)) out", systemImage: "text.cursor")
            Label("\(Self.k(t.in + t.cache_write + t.cache_read)) in", systemImage: "tray.and.arrow.down")
        }
        .font(.caption).foregroundStyle(.secondary)
        .help("Tokens this session used, from Claude Code's own transcript. Input includes cache reads (\(Self.k(t.cache_read))) and writes (\(Self.k(t.cache_write))), which is most of it.")
    }

    static func k(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0fk", Double(n) / 1e3) : "\(n)"
    }

    // MARK: one turn

    private var detail: some View { turnDetail }

    private var turnDetail: some View {
        ScrollView {
            if model.showPinnedTurns, let p = model.pinnedPick {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Pinned from \(p.sessionTitle)", systemImage: "pin.fill").font(.callout.weight(.semibold)).foregroundStyle(.red)
                        Spacer()
                        Button { Paster.pasteIntoClaude(p.answer) } label: { Label("Paste into Claude", systemImage: "arrow.right.doc.on.clipboard") }
                            .controlSize(.small).help("Hand this answer back to Claude, in its message box. You press Enter")
                        Button { model.unpin(p) } label: { Label("Unpin", systemImage: "pin.slash") }.controlSize(.small)
                    }
                    Text(p.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    MarkdownView(text: p.answer.isEmpty ? "(no text answer)" : p.answer)
                }
                .padding(18)
            } else if model.showPinnedTurns {
                Text("Pin a prompt from any session (right-click it, or the pin button).").foregroundStyle(.secondary).padding(40)
            } else if let t = model.turn {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        if t.byClaude == true {
                            Label("Started by Claude", systemImage: "sparkle").font(.callout.weight(.semibold)).foregroundStyle(.purple)
                                .help("Another session handed this task to a new one. These are its instructions, not a prompt of yours")
                        } else {
                            Label("You", systemImage: "person.fill").font(.callout.weight(.semibold)).foregroundStyle(.blue)
                        }
                        if let d = t.date { Text(d.formatted(date: .complete, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { model.togglePin(t) } label: {
                            Label(model.isPinned(t) ? "Pinned" : "Pin", systemImage: model.isPinned(t) ? "pin.fill" : "pin")
                        }
                        .controlSize(.small)
                        .help("Keep this prompt and answer at the top, and in Pinned answers")
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t.prompt, forType: .string) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)
                    }
                    Text(t.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    // Sent while Claude was working: the same turn, answered together.
                    ForEach(Array((t.also ?? []).enumerated()), id: \.offset) { _, a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("While Claude was working").font(.caption).foregroundStyle(.secondary)
                            Text(a).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !t.images.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                            ForEach(t.images, id: \.self) { Thumb(path: $0, size: 160) }
                        }
                    }
                    HStack {
                        Label("Claude", systemImage: "sparkle").font(.callout.weight(.semibold)).foregroundStyle(.purple)
                        Text("\(t.tools) tool calls · \(Self.k(t.out)) tokens out · \(Self.k(t.in)) in").font(.caption).foregroundStyle(.secondary)
                    }
                    MarkdownView(text: t.shownAnswer)
                }
                .padding(18)
            } else {
                Text("Pick a turn").foregroundStyle(.secondary).padding(40)
            }
        }
    }
}

// An image from a session, as a thumbnail; click through to Preview with a double click.
// A picture, as a small cached thumbnail (decoded once at thumbnail size, off the main thread).
// A click acts at once; a double-click (read from the click itself, not a second gesture that
// makes SwiftUI wait to tell the two apart) opens the full picture.
final class ThumbCache {
    nonisolated(unsafe) static let shared = NSCache<NSString, NSImage>()  // NSCache is thread-safe
    static func thumb(_ path: String, px: CGFloat) -> NSImage? {
        let key = "\(path)#\(Int(px))" as NSString
        if let img = shared.object(forKey: key) { return img }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: px, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        shared.setObject(img, forKey: key)
        return img
    }
}
final class ThumbModel: ObservableObject { @Published var image: NSImage? }

private struct Thumb: View {
    let path: String
    var size: CGFloat = 100
    var onTap: (() -> Void)? = nil
    @StateObject private var m = ThumbModel()
    var body: some View {
        Group {
            if let img = m.image ?? ThumbCache.shared.object(forKey: "\(path)#\(Int(size * 3))" as NSString) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: size, height: size * 0.7)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.edge, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSApp.currentEvent?.clickCount ?? 1 >= 2 { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } else { onTap?() }
        }
        .task(id: path) {
            guard m.image == nil else { return }
            let p = path, px = size * 3
            let img = await Task.detached(priority: .userInitiated) { ThumbCache.thumb(p, px: px) }.value
            m.image = img
        }
    }
}


// The pin's column: always the same width, empty when not pinned.
struct PinMark: View {
    let on: Bool
    var body: some View {
        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.red).opacity(on ? 1 : 0).frame(width: 12)
    }
}


// Open the session in the Claude app. The rest is for developers (Settings → General → Developer).
struct SessionActions: View {
    let session: HistorySession
    @AppStorage("dev.tools") private var dev = false
    var body: some View {
        // The Claude app's own claude:// links (support.claude.com, "Open Claude Desktop with a link").
        Button("Open in Claude") { Self.openInClaude(session) }
            .help("Opens this session in the Claude app, if it's one the app knows (sessions started in Terminal aren't)")
        if dev {
            Divider()
            Button("New Claude session in this folder") {
                var c = URLComponents(); c.scheme = "claude"; c.host = "code"; c.path = "/new"
                c.queryItems = [URLQueryItem(name: "folder", value: session.project)]
                if let u = c.url { NSWorkspace.shared.open(u) }
            }
            Button("Copy session ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.id, forType: .string) }
            Button("Show transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)]) }
            Button("Resume in Terminal") { Self.terminal("claude --resume \(session.id)", in: session.project) }
        }
    }

    static func open(_ link: String) { if let u = URL(string: link) { NSWorkspace.shared.open(u) } }
    // The Claude app names its sessions with its own id (local_…); bin/kite looks it up.
    static func openInClaude(_ s: HistorySession) {
        guard let root = Kite.root else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli)
        p.arguments = ["app-session", s.id]
        let out = Pipe(); p.standardOutput = out
        guard (try? p.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        // Routes from the Claude app's own link handler: code/continue opens one of its sessions;
        // resume imports a Claude Code session it hasn't seen (started in Terminal) and opens it.
        if let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], d["here"] as? Bool == false {
            let a = NSAlert()
            a.messageText = "This session is in another Claude account's sidebar"
            a.informativeText = "The Claude app keeps one sidebar per account, so it can't open it while you're signed in to this one. You can go on with it in Terminal instead: same conversation, on your current login."
            a.addButton(withTitle: "Resume in Terminal"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { terminal("claude --resume \(s.id)", in: s.project) }
        } else if let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = d["id"] as? String {
            open("claude://code/continue?session=" + id)
        } else {
            let a = NSAlert()
            a.messageText = "Bring this session into the Claude app?"
            a.informativeText = "It was started outside the app (in Terminal). The Claude app can import it and open it there; the original stays as it is."
            a.addButton(withTitle: "Import and open"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { open("claude://resume?session=" + s.id) }
        }
    }
    // Run from the session's own folder, so Claude Code finds it.
    static func terminal(_ command: String, in dir: String) {
        let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let line = (FileManager.default.fileExists(atPath: dir) ? "cd \(quoted) && " : "") + command
        let script = "tell application \"Terminal\"\nactivate\ndo script \"" + line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"\nend tell"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { Log.line("history: Terminal: \(err)") }
    }
}


extension HistoryModel {
    // A name, asked the Mac way. Nil when cancelled or left empty.
    static func ask(_ title: String, name: String, button: String = "Create") -> String? {
        let a = NSAlert(); a.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = name
        a.accessoryView = field
        a.addButton(withTitle: button); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let n = field.stringValue.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }
}

private struct FolderHeader: View {
    @ObservedObject var model: HistoryModel
    let folder: HistoryFolder
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(folder.name)
            Spacer()
            Text("\(model.sessions(in: folder).count)").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(model.dropTarget == folder.id ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in model.move(ids, to: folder.id); return true } isTargeted: { on in
            if on { model.dropTarget = folder.id } else if model.dropTarget == folder.id { model.dropTarget = nil }
        }
        .contextMenu {
            Button("Rename Folder") { HistoryModel.ask("Rename Folder", name: folder.name, button: "Rename").map { model.rename(folder, to: $0) } }
            Button("Delete Folder") { model.delete(folder) }
                .help("The sessions go back to the list")
            Divider()
            Button("New Folder") { HistoryModel.ask("New Folder", name: "New Folder").map { model.newFolder($0) } }
        }
    }
}

private struct SessionsToggle: View {
    @ObservedObject var model: HistoryModel
    var body: some View {
        Button {
            withAnimation { model.columns = model.columns == .all ? .doubleColumn : .all }
        } label: { Image(systemName: "sidebar.left").font(.system(size: 14)) }
            .buttonStyle(.borderless)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help(model.columns == .all ? "Hide the sessions (⌃⌘S)" : "Show the sessions (⌃⌘S)")
            .frame(width: 40, height: 28)
    }
}

// A small grey tag after a session's name: other account, fork, archived.
struct Pill: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
            .fixedSize()
    }
}

// PurpleRestore: SantaRow's separate app for bringing sessions back into the Claude app's sidebar
// after an account switch. Workshop only opens it.
@MainActor
enum PurpleRestore {
    static func open() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.santarow.purplerestore")
            ?? ["/Applications/PurpleRestore.app", NSHomeDirectory() + "/Applications/PurpleRestore.app"]
                .map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        if let url { NSWorkspace.shared.openApplication(at: url, configuration: .init()); return }
        let a = NSAlert()
        a.messageText = "PurpleRestore isn't installed yet"
        a.informativeText = "It's SantaRow's separate app for bringing sessions from another Claude account back into the Claude app's sidebar. Until then, you can go on with any of them in Terminal: right-click a session → Open in Claude."
        a.runModal()
    }
}

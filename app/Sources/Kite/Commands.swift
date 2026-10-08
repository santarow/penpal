import AppKit
import SwiftUI

// Everything Claude can do that's hidden behind menus, slash commands and key combos, in one
// place. The Claude app's own menus are read live through Accessibility, so they match the
// installed version; Claude Code's commands and keys come from its docs (data/claude-code.json).
// Clicking a command pastes it into Claude's message box. Kite never presses Enter for you.

struct MenuCommand: Identifiable {
    let id = UUID()
    let menu: String
    let title: String
    let keys: String
    let element: AXUIElement
}

struct CodeCommand: Decodable, Identifiable {
    let name, usage, kind, what: String
    var id: String { name }
}

struct CodeAction: Decodable, Identifiable {
    let group, action, keys, what: String
    let custom: Bool?
    var id: String { action }
}

struct QuickKey: Decodable, Identifiable {
    let keys, what: String
    var id: String { keys }
}

// bin/kite commands: the docs' lists with the user's own skills and keybindings.json laid on top.
private struct CodeDoc: Decodable {
    let fetched: String
    let keybindings: Bool
    let commands: [CodeCommand]
    let actions: [CodeAction]
    let quick: [QuickKey]
}

@MainActor
final class CommandsModel: ObservableObject {
    @Published var menus: [MenuCommand] = []
    @Published var claudeRunning = false
    @Published var code: [CodeCommand] = []
    @Published var actions: [CodeAction] = []
    @Published var quick: [QuickKey] = []
    @Published var refreshing = false
    @Published var docNote = ""
    @Published var search = ""
    @Published var tab = 0

    func load() {
        loadDoc()
        readMenus()
    }

    private func loadDoc() {
        kite(["commands"]) { data in
            guard let data, let doc = try? JSONDecoder().decode(CodeDoc.self, from: data) else { return }
            self.code = doc.commands
            self.actions = doc.actions
            self.quick = doc.quick
            self.docNote = "Built-ins from the Claude Code docs, fetched \(doc.fetched). Yours from ~/.claude/skills and commands."
                + (doc.keybindings ? " Keys include your ~/.claude/keybindings.json." : " You haven't changed any keys (no ~/.claude/keybindings.json).")
        }
    }

    // Re-downloads the lists, for when Claude Code adds commands.
    func refreshFromDocs() {
        refreshing = true
        kite(["commands", "refresh"]) { _ in
            self.refreshing = false
            self.loadDoc()
        }
    }

    private func kite(_ args: [String], done: @escaping @MainActor (Data?) -> Void) {
        guard let root = Kite.root else { return done(nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli)
        p.arguments = args
        var env = Kite.engineEnv
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { p in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let ok = p.terminationStatus == 0
            Task { @MainActor in
                if !ok { Log.line("helper \(args.joined(separator: " ")) failed") }
                done(ok ? data : nil)
            }
        }
        do { try p.run() } catch { done(nil) }
    }

    // Walks the Claude app's menu bar: every item, with its shortcut if it has one.
    func readMenus() {
        guard let app = Expander.claudeApps.lazy
            .compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first else {
            claudeRunning = false
            menus = []
            return
        }
        claudeRunning = true
        func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(e, n as CFString, &v)
            return v
        }
        func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }
        var out: [MenuCommand] = []
        guard let bar = attr(AXUIElementCreateApplication(app.processIdentifier), "AXMenuBar") else { return }
        for top in kids(bar as! AXUIElement).dropFirst() {  // skip the Apple menu
            let menuName = attr(top, "AXTitle") as? String ?? ""
            func walk(_ e: AXUIElement, _ path: String) {
                for item in kids(e).flatMap({ attr($0, "AXRole") as? String == "AXMenu" ? kids($0) : [$0] }) {
                    guard let title = attr(item, "AXTitle") as? String, !title.isEmpty else { continue }
                    let sub = kids(item).first { attr($0, "AXRole") as? String == "AXMenu" }
                    if let sub {
                        if title != "Services" { walk(sub, path + " › " + title) }  // macOS's, not Claude's
                        continue
                    }
                    if Self.risky.contains(where: { title.localizedCaseInsensitiveContains($0) }) { continue }
                    out.append(MenuCommand(menu: path, title: title, keys: Self.keys(item, attr), element: item))
                }
            }
            walk(top, menuName)
        }
        menus = out
    }

    // Left out: these end your session or delete things.
    static let risky = ["Quit", "Log Out", "Sign Out", "Delete", "Hide"]

    private static func keys(_ item: AXUIElement, _ attr: (AXUIElement, String) -> CFTypeRef?) -> String {
        let char = attr(item, "AXMenuItemCmdChar") as? String ?? ""
        let glyph = attr(item, "AXMenuItemCmdGlyph") as? Int ?? 0
        guard !char.isEmpty || glyph != 0 else { return "" }
        let mods = attr(item, "AXMenuItemCmdModifiers") as? Int ?? 0  // bits: 1 ⇧, 2 ⌥, 4 ⌃, 8 no ⌘
        var s = ""
        if mods & 4 != 0 { s += "⌃" }
        if mods & 2 != 0 { s += "⌥" }
        if mods & 1 != 0 { s += "⇧" }
        if mods & 8 == 0 { s += "⌘" }
        let glyphs: [Int: String] = [0x17: "⌫", 0x04: "↩", 0x0B: "↩", 0x1B: "⎋", 0x64: "←", 0x65: "→", 0x68: "↑", 0x6A: "↓", 0x09: "Space", 0x02: "⇥"]
        return s + (char.isEmpty ? (glyphs[glyph] ?? "") : char.uppercased())
    }

    // Runs a Claude menu item by its title (e.g. "New Session"), for the dock's session row.
    // Presses a Claude menu item by its title. false when there's no such item, or Claude has it
    // greyed out (Reopen Closed Session with nothing closed): nothing is pressed then.
    @discardableResult
    static func run(title: String) -> Bool {
        let model = CommandsModel()
        model.readMenus()
        guard let item = model.menus.first(where: { $0.title == title }) else {
            Log.line("claude menu: no \"\(title)\" (is Claude open?)")
            return false
        }
        var enabled: CFTypeRef?
        AXUIElementCopyAttributeValue(item.element, "AXEnabled" as CFString, &enabled)
        if (enabled as? Bool) == false {
            Log.line("claude menu: \"\(title)\" is greyed out in Claude")
            return false
        }
        model.run(item)
        return true
    }

    // Runs a Claude menu item, with Claude brought forward first.
    func run(_ m: MenuCommand) {
        if let app = Expander.claudeApps.lazy.compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first {
            app.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let ok = AXUIElementPerformAction(m.element, "AXPress" as CFString) == .success
            Log.line("claude menu \(m.menu) › \(m.title): \(ok ? "ran" : "failed")")
        }
    }
}

@MainActor
enum CommandsWindow {
    private static var window: NSWindow?
    private static let model = CommandsModel()

    static func toggle() {
        if let w = window, w.isVisible, w.isKeyWindow, NSApp.isActive { return w.performClose(nil) }
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Claude Commands"
            let host = NSHostingView(rootView: CommandsView(model: model))
            host.sizingOptions = [.minSize]
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            return w
        }()
        model.load()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

struct CommandsView: View {
    @ObservedObject var model: CommandsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.tab) {
                    Text("Claude app").tag(0)
                    Text("Claude Code commands").tag(1)
                    Text("Claude Code keys").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if model.tab > 0 {
                    Button { model.refreshFromDocs() } label: {
                        Label(model.refreshing ? "Refreshing…" : "Refresh from docs", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.refreshing)
                    .help("Download the latest command and key lists from code.claude.com/docs")
                }
                // Flexible: on the current SDK the segmented control is wider, and a fixed 200 ran off the window (#273).
                TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(minWidth: 120, maxWidth: 200)
            }
            .padding(12)
            Divider()
            switch model.tab {
            case 0: appMenus
            case 1: codeCommands
            default: codeKeys
            }
        }
        .frame(minWidth: 600, minHeight: 420)
    }

    private func matches(_ parts: String...) -> Bool {
        let q = model.search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || parts.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private var appMenus: some View {
        let items = model.menus.filter { matches($0.title, $0.menu, $0.keys) }
        let order = items.map(\.menu).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }  // menu bar order
        return VStack(spacing: 0) {
            if !model.claudeRunning {
                Text("Open the Claude app to see its menus and shortcuts here.").foregroundStyle(.secondary).padding(30)
            }
            List {
                ForEach(order, id: \.self) { menu in
                    let rows = items.filter { $0.menu == menu }
                    Section(menu) {
                        ForEach(rows) { m in
                            HStack {
                                Text(m.title)
                                Spacer()
                                Text(m.keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                                Button("Run") { model.run(m) }.buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            Text("Read live from the Claude app's menus. Run clicks the menu item for you; Quit, Delete and Log Out are left out.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }

    private var codeCommands: some View {
        let items = model.code.filter { matches($0.name, $0.what) }
        return VStack(spacing: 0) {
            List(items) { c in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(c.usage).font(.system(.body, design: .monospaced)).frame(width: 220, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.what).lineLimit(3)
                        if c.kind != "built-in" {
                            let mine = c.kind.contains("your") || c.kind.contains("synced")
                            Text(mine ? "yours · \(c.kind)" : c.kind).font(.caption2)
                                .foregroundStyle(mine ? Color.accentColor : .secondary)
                        }
                    }
                    Spacer()
                    Button("Paste") { Paster.pasteIntoClaude(c.name + " ") }
                        .buttonStyle(.link)
                        .help("Put \(c.name) in Claude's message box. You press Enter")
                }
            }
            Text(model.docNote).font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }

    private var codeKeys: some View {
        let acts = model.actions.filter { matches($0.keys, $0.what, $0.action) }
        let quick = model.quick.filter { matches($0.keys, $0.what) }
        let order = acts.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return VStack(spacing: 0) {
            List {
                if !quick.isEmpty {
                    Section("Typed at the start of a message") {
                        ForEach(quick) { k in keyRow(k.keys, k.what, custom: false) }
                    }
                }
                ForEach(order, id: \.self) { group in
                    Section(group) {
                        ForEach(acts.filter { $0.group == group }) { a in keyRow(a.keys, a.what, custom: a.custom == true) }
                    }
                }
            }
            Text(model.docNote).font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }

    private func keyRow(_ keys: String, _ what: String, custom: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(keys).font(.system(.body, design: .monospaced)).frame(width: 220, alignment: .leading)
                .foregroundStyle(keys == "(unbound)" ? .tertiary : .primary)
            Text(what)
            Spacer()
            if custom { Text("custom").font(.caption2).foregroundStyle(Color.accentColor) }
        }
    }
}

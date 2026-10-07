import AppKit
import SwiftUI

// The Lenses window, laid out like Typinator: sets on the left (with an on/off box each), the
// set's lenses in the middle (abbreviation and summary), the selected lens on the right to edit
// and use. Opened from the dock's lens row (Edit lenses…) or the menu bar.
@MainActor
final class LensEditor: ObservableObject {
    let store: LensStore
    @Published var set = LensStore.mySet
    @Published var selected: Lens?
    @Published var name = ""
    @Published var abbrev = ""
    @Published var summary = ""
    @Published var body = ""
    @Published var dirty = false
    @Published var version = 0  // bumped after a save or delete, so lists re-read the folders
    @Published var newSetName = ""
    @Published var search = ""

    init(store: LensStore) { self.store = store }

    func pick(_ lens: Lens?) {
        selected = lens
        guard let lens else { name = ""; abbrev = ""; summary = ""; body = ""; dirty = false; return }
        let p = LensStore.parts(of: lens)
        name = lens.name; abbrev = store.abbreviation(lens.name); summary = p.summary; body = p.body; dirty = false
    }

    func newLens() {
        selected = nil
        name = ""; abbrev = ""; summary = ""; body = ""; dirty = true
        if LensStore.isBuiltIn(set) { set = LensStore.mySet }
    }

    func save() {
        // The name is optional: without one, the abbreviation names it (";ss" → "ss").
        let given = name.trimmingCharacters(in: .whitespaces)
        let named = given.isEmpty ? LensStore.name(from: abbrev) : given
        guard let saved = store.save(name: named, summary: summary, body: body, set: set, replacing: selected) else { return }
        store.setAbbreviation(saved.name, abbrev.isEmpty ? ";" + saved.name : abbrev, was: selected?.name)
        set = saved.group
        version += 1
        pick(saved)
        Log.line("lens saved: \(saved.id)")
    }

    func delete() {
        guard let lens = selected, !lens.builtIn else { return }
        store.delete(lens)
        version += 1
        pick(nil)
    }
}

@MainActor
enum LensWindow {
    private static var window: NSWindow?
    private static var editor: LensEditor?

    static func open(_ store: LensStore) {
        if let w = window { NSApp.activate(); w.makeKeyAndOrderFront(nil); return }
        let ed = LensEditor(store: store)
        editor = ed
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Snippets"
        let host = NSHostingView(rootView: LensWindowView(ed: ed))
        host.sizingOptions = [.minSize]
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

private struct LensWindowView: View {
    @ObservedObject var ed: LensEditor

    var body: some View {
        NavigationSplitView {
            // A range alone was ignored and left the sets cut off ("M…"); a frame holds it (#273, as Settings' #272).
            sets.frame(minWidth: 200, idealWidth: 210).navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 260).background(Palette.background)
                .toolbar(removing: .sidebarToggle)
        } content: {
            list.navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            editor.background(Palette.background)
        }
        .frame(minWidth: 860, minHeight: 480)
    }

    // MARK: sets

    private var sets: some View {
        let _ = ed.version
        return VStack(spacing: 0) {
            List(selection: Binding(get: { ed.set }, set: { if let s = $0 { ed.set = s; ed.pick(nil) } })) {
                Section("Sets") {
                    ForEach(ed.store.sets(), id: \.self) { s in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { ed.store.isOn(s) }, set: { ed.store.setOn(s, $0); ed.version += 1 }))
                                .labelsHidden().toggleStyle(.checkbox)
                                .help("Off: its snippets don't paste or expand")
                            Image(systemName: LensStore.isBuiltIn(s) ? "shippingbox" : "folder")
                            Text(LensStore.title(s))
                            Spacer()
                            Text("\(ed.store.lenses(in: s).count)").foregroundStyle(.secondary).font(.caption)
                        }
                        .tag(s)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            HStack(spacing: 6) {
                TextField("New set", text: $ed.newSetName).textFieldStyle(.roundedBorder)
                Button {
                    let n = ed.newSetName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    ed.store.addSet(n); ed.newSetName = ""; ed.set = n; ed.version += 1
                } label: { Image(systemName: "folder.badge.plus") }
                .help("Make a set")
            }
            .padding(8)
            Button("Restore Defaults…") { ed.store.restoreDefaultsAsking(); ed.version += 1 }
                .buttonStyle(.link).font(.caption).padding(.bottom, 8)
                .help("Puts back the default snippets you deleted; asks before resetting any you changed")
        }
    }

    // MARK: the set's lenses

    private var list: some View {
        let _ = ed.version
        let all = ed.store.lenses(in: ed.set)
        let q = ed.search.lowercased()
        let shown = q.isEmpty ? all : all.filter { $0.name.contains(q) || LensStore.parts(of: $0).summary.lowercased().contains(q) }
        return VStack(spacing: 0) {
            HStack {
                Text(LensStore.title(ed.set)).font(.headline)  // "My snippets", not the set's inside name
                Spacer()
                Button { ed.newLens() } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless).help("New snippet")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            TextField("Search", text: $ed.search).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 6)
            Table(shown, selection: Binding(get: { ed.selected?.id }, set: { id in ed.pick(all.first { $0.id == id }) })) {
                TableColumn("Abbreviation") { l in Text(ed.store.abbreviation(l.name)).font(.body.monospaced()) }.width(min: 80, ideal: 100)
                TableColumn("Name") { l in Text(l.name) }.width(min: 70, ideal: 90)
                TableColumn("Summary") { l in Text(LensStore.parts(of: l).summary).foregroundStyle(.secondary).lineLimit(1) }
            }
            if all.isEmpty {
                Text(LensStore.isBuiltIn(ed.set) ? "No built-in snippets found." : "Empty set. + to add a snippet.")
                    .foregroundStyle(.secondary).padding()
            }
        }
    }

    // MARK: the lens

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ed.selected == nil && !ed.dirty {
                Spacer()
                Text("Pick a snippet, or + to make one.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Abbreviation").font(.headline)
                        TextField(";" + (ed.name.isEmpty ? "name" : ed.name), text: $ed.abbrev)
                            .font(.title3.monospaced()).textFieldStyle(.roundedBorder)
                            .onChange(of: ed.abbrev) { ed.dirty = true }
                        let clash = ed.store.clashes(ed.abbrev.isEmpty ? ";" + ed.name : ed.abbrev, except: ed.name)
                        if !clash.isEmpty {
                            Text("Also used by \(clash.joined(separator: ", ")): the longer or first one wins").font(.caption).foregroundStyle(.red)
                        } else {
                            Text("What you type in Claude. Anything: ;chill, cc, //c").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.headline)
                        TextField("optional", text: $ed.name).font(.title3).textFieldStyle(.roundedBorder)
                            .onChange(of: ed.name) { ed.dirty = true }
                        Text("Optional. For menus; empty uses the abbreviation").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 180)
                }
                Text("Summary").font(.headline)
                TextField("One line: what this snippet does", text: $ed.summary).textFieldStyle(.roundedBorder)
                    .onChange(of: ed.summary) { ed.dirty = true }
                Text("Expansion").font(.headline)
                TextEditor(text: $ed.body)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .fieldBox(radius: 6)
                    .onChange(of: ed.body) { ed.dirty = true }
                HStack {
                    Text("Pastes exactly this. {n} counts up: img{n} → img1, img2…, back to 1 after five quiet minutes")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if ed.body.contains("{n}"), let l = ed.selected, ed.store.counter(l.name) > 0 {
                        Button("Restart at 1 (now \(ed.store.counter(l.name)))") { ed.store.resetCounter(l.name); ed.version += 1 }
                            .controlSize(.small)
                    }
                }
                if ed.selected?.builtIn == true {
                    Text("A built-in snippet. Saving makes your own copy in My snippets, which replaces it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save") { ed.save() }.keyboardShortcut("s").disabled(!ed.dirty || (ed.name.isEmpty && LensStore.name(from: ed.abbrev).isEmpty))
                    if let l = ed.selected, !l.builtIn { Button("Delete", role: .destructive) { ed.delete() } }
                    Spacer()
                    if let l = ed.selected {
                        Menu("Use") {
                            Button("Paste into Claude") { if let t = ed.store.expansion(l.name) { Paster.pasteIntoClaude(t) } }
                            Button("New Claude session with it") {
                                CommandsModel.run(title: "New Session")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if let t = ed.store.expansion(l.name) { Paster.pasteIntoClaude(t) } }
                            }
                            Button("New Claude window with it") { ed.store.openInNewWindow(l.name) }
                            Divider()
                            Button("Agents talk this way") { AgentStore.shared.setMode(l.name) }
                        }
                        .fixedSize()
                    }
                }
                Text("Type \(ed.abbrev.isEmpty ? ";" + (ed.name.isEmpty ? "name" : ed.name) : ed.abbrev) in Claude's message box and it becomes this text. You still press Enter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

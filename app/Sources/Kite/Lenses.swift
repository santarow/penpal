import AppKit

// Lenses: named prompts you paste into Claude (the dock, or type ;name in Claude). Read fresh on
// every use, so edits apply at once.
//
//   Yours       ~/.kite/lenses/*.md is the set "My lenses"; each subfolder is another set
//   Defaults    the repo's lenses/ folder (path written by build-app.sh), else the copy bundled in the app:
//               copied into yours on first load, and by Restore defaults (#261); never shown as a set
//
// A lens file: "# name", a blank line, "> one-line summary", a blank line, then the text. A set can be
// switched off (Typinator-style).
struct Lens: Identifiable, Hashable {
    let name: String       // the abbreviation, without the ;
    let group: String      // its set
    let url: URL
    var id: String { group + "/" + name }
    var builtIn: Bool { LensStore.isBuiltIn(group) }  // none since #261: every snippet is yours
}

struct LensStore {
    static let builtInSet = "Built-in"
    static let funSet = "Fun"
    static func isBuiltIn(_ set: String) -> Bool { set == builtInSet }
    static let mySet = "My lenses"  // its name inside (set switches are saved by it); shown as "My snippets"
    static func title(_ set: String) -> String { set == mySet ? "My snippets" : set }
    let folder: URL  // the defaults
    static let userRoot = Kite.read("lenses")  // ~/.kite's while only it has yours (#310)

    static func locate() -> LensStore {
        if let path = (Bundle.main.object(forInfoDictionaryKey: "SantaRowLensesPath") ?? Bundle.main.object(forInfoDictionaryKey: "KiteLensesPath")) as? String,
           FileManager.default.fileExists(atPath: path) {
            return LensStore(folder: URL(fileURLWithPath: path))
        }
        return LensStore(folder: Bundle.main.resourceURL!.appendingPathComponent("lenses"))
    }

    // MARK: defaults (#261, Jason: "people can add or delete them if they want, but its the first load")

    // Each default and where it goes: the top folder into My snippets, fun/ into the set "Fun".
    func defaults() -> [(name: String, url: URL, set: String)] {
        [("", Self.mySet), ("fun", Self.funSet)].flatMap { sub, set in
            ((try? FileManager.default.contentsOfDirectory(at: sub.isEmpty ? folder : folder.appendingPathComponent(sub),
                                                           includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "md" }
                .map { (name: $0.deletingPathExtension().lastPathComponent.lowercased(), url: $0, set: set) }
                .sorted { $0.name < $1.name }
        }
    }
    // Every name you have, in any set, switched on or off.
    private func yourNames() -> Set<String> { Set(sets().flatMap { lenses(in: $0).map(\.name) }) }

    // Each default is offered once, at launch: copied into yours unless you have one by that name. The names
    // offered are kept in ~/.kite/lenses/.defaults (shared by Penpal and Kite), so one you delete stays deleted,
    // and a default added later still arrives. Fun starts off for someone new; for whoever had snippets already
    // its lenses were in their menu, so it stays on.
    static let offeredFile = userRoot.appendingPathComponent(".defaults")
    func seedDefaults() {
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: Self.userRoot.path)
        var offered = Set(((try? String(contentsOf: Self.offeredFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        var have = yourNames(), added: [String] = [], funNew = !fm.fileExists(atPath: folder(of: Self.funSet).path)
        for d in defaults() where !offered.contains(d.name) {
            offered.insert(d.name)
            guard !have.contains(d.name) else { continue }
            try? fm.createDirectory(at: folder(of: d.set), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: d.url, to: folder(of: d.set).appendingPathComponent(d.name + ".md"))) != nil {
                have.insert(d.name); added.append(d.name)
            }
        }
        if funNew && isNew && fm.fileExists(atPath: folder(of: Self.funSet).path) { setOn(Self.funSet, false) }
        try? fm.createDirectory(at: Self.userRoot, withIntermediateDirectories: true)
        try? (offered.sorted().joined(separator: "\n") + "\n").write(to: Self.offeredFile, atomically: true, encoding: .utf8)
        if !added.isEmpty { Log.line("snippets: added the defaults \(added.joined(separator: ", "))") }
    }

    // Restore defaults: the ones missing come back where first load put them. Ones you have with other text are
    // returned, and only replaced by the original when `replace` (the caller asks first).
    @discardableResult
    func restoreDefaults(replace: Bool) -> [String] {
        let fm = FileManager.default
        let mine = Dictionary(sets().flatMap { lenses(in: $0) }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var changed: [String] = []
        for d in defaults() {
            if let have = mine[d.name] {
                guard (try? Data(contentsOf: have.url)) != (try? Data(contentsOf: d.url)) else { continue }
                changed.append(d.name)
                if replace { _ = try? fm.removeItem(at: have.url); try? fm.copyItem(at: d.url, to: have.url) }
            } else {
                try? fm.createDirectory(at: folder(of: d.set), withIntermediateDirectories: true)
                try? fm.copyItem(at: d.url, to: folder(of: d.set).appendingPathComponent(d.name + ".md"))
            }
        }
        return changed
    }

    // The button's whole job: put back what's missing, then ask before replacing any you changed.
    @MainActor
    func restoreDefaultsAsking() {
        let changed = restoreDefaults(replace: false)
        guard !changed.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Also reset \(changed.joined(separator: ", ")) to the original?"
        alert.informativeText = "The missing default snippets are back. These you have with other text; resetting replaces your text."
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Reset")
        if alert.runModal() == .alertSecondButtonReturn { restoreDefaults(replace: true) }
    }

    // MARK: sets

    // Every set: My lenses, then subfolders by name.
    func sets() -> [String] {
        let subs = ((try? FileManager.default.contentsOfDirectory(at: Self.userRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted()
        return [Self.mySet] + subs
    }
    func folder(of set: String) -> URL {
        set == Self.builtInSet ? folder : set == Self.mySet ? Self.userRoot : Self.userRoot.appendingPathComponent(set)
    }
    static var offSets: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "lens.sets.off") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "lens.sets.off") }
    }
    func isOn(_ set: String) -> Bool { !Self.offSets.contains(set) }
    func setOn(_ set: String, _ on: Bool) {
        var off = Self.offSets
        if on { off.remove(set) } else { off.insert(set) }
        Self.offSets = off
    }
    func addSet(_ name: String) {
        try? FileManager.default.createDirectory(at: Self.userRoot.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    // MARK: lenses

    func lenses(in set: String) -> [Lens] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(of: set), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
            .map { Lens(name: $0.deletingPathExtension().lastPathComponent.lowercased(), group: set, url: $0) }
            .sorted { $0.name < $1.name }
    }

    // The lens each name means right now: sets that are on, yours over the built-in ones.
    func active() -> [String: Lens] {
        var out: [String: Lens] = [:]
        for set in sets() where isOn(set) {
            for lens in lenses(in: set) where out[lens.name] == nil || out[lens.name]!.builtIn { out[lens.name] = lens }
        }
        return out
    }

    func names() -> [String] { active().keys.sorted() }

    func text(_ name: String) -> String? {
        guard let lens = active()[name] else { return nil }
        return try? String(contentsOf: lens.url, encoding: .utf8)
    }

    // The one-line summary after "> ".
    func summary(_ name: String) -> String {
        guard let lens = active()[name] else { return "" }
        return Self.parts(of: lens).summary
    }

    static func parts(of lens: Lens) -> (summary: String, body: String) {
        let text = (try? String(contentsOf: lens.url, encoding: .utf8)) ?? ""
        var lines = text.components(separatedBy: "\n")
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        var summary = ""
        if let first = lines.first, first.hasPrefix("> ") { summary = String(first.dropFirst(2)); lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        // Exactly as written: inner and trailing spaces and line breaks stay; only the file's own
        // final newline is not part of the lens.
        var body = lines.joined(separator: "\n")
        if body.hasSuffix("\n") { body.removeLast() }
        return (summary, body)
    }

    // Writes a lens into one of your sets (a built-in edited becomes your copy in My lenses).
    @discardableResult
    func save(name: String, summary: String, body: String, set: String, replacing old: Lens? = nil) -> Lens? {
        let clean = name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !clean.isEmpty else { return nil }
        let target = Self.isBuiltIn(set) ? Self.mySet : set
        let dir = folder(of: target)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(clean).md")
        // The body as you typed it (a trailing space, blank lines inside); only leading empty lines go.
        var kept = body
        while kept.hasPrefix("\n") { kept.removeFirst() }
        let text = "# \(clean)\n\n" + (summary.isEmpty ? "" : "> \(summary)\n\n") + kept + "\n"
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        if let old, !old.builtIn, old.url != url { try? FileManager.default.removeItem(at: old.url) }  // renamed
        return Lens(name: clean, group: target, url: url)
    }

    // MARK: abbreviations (what you type to paste a lens), yours to choose: ";chill", "cc", "//c"…
    // Kept in ~/.kite/lenses/abbreviations.json; a lens without one uses ";" + its name.
    static let abbreviationsFile = userRoot.appendingPathComponent("abbreviations.json")
    private static func loadAbbreviations() -> [String: String] {
        (try? Data(contentsOf: abbreviationsFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
    func abbreviation(_ name: String) -> String { Self.loadAbbreviations()[name] ?? ";" + name }
    func setAbbreviation(_ name: String, _ abbrev: String, was old: String? = nil) {
        var all = Self.loadAbbreviations()
        if let old, old != name { all[old] = nil }
        let a = abbrev.trimmingCharacters(in: .whitespacesAndNewlines)
        all[name] = a.isEmpty || a == ";" + name ? nil : String(a.prefix(32))
        try? FileManager.default.createDirectory(at: Self.userRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: Self.abbreviationsFile) }
    }
    // Every active lens's abbreviation, longest first (so "cc2" wins over "cc").
    func triggers() -> [(abbrev: String, name: String)] {
        let map = Self.loadAbbreviations()
        return names().map { (map[$0] ?? ";" + $0, $0) }.sorted { $0.abbrev.count > $1.abbrev.count }
    }
    // Lenses that share an abbreviation with another one (only one can win).
    func clashes(_ abbrev: String, except name: String) -> [String] {
        triggers().filter { $0.abbrev.lowercased() == abbrev.lowercased() && $0.name != name }.map(\.name)
    }

    // What a lens pastes: exactly its text (the file's "# name" and "> summary" lines are the lens's
    // label, not part of the text; a lens that wants a heading has one in its text). {n} counts up:
    // "img{n}" pastes img1, img2… for the pictures in one message, and starts over at 1 after
    // five quiet minutes (the next message).
    func expansion(_ name: String) -> String? {
        guard let lens = active()[name] else { return nil }
        var body = Self.parts(of: lens).body  // exactly as saved: ";p" → "🏞️ {n} " keeps its trailing space
        if body.contains("{n}") {
            var counts = Self.loadCounters()
            let last = counts[name]
            let n = last.map { Date.now.timeIntervalSince1970 - $0.at < Self.counterRestart ? $0.n + 1 : 1 } ?? 1
            counts[name] = Count(n: n, at: Date.now.timeIntervalSince1970)
            Self.saveCounters(counts)
            body = body.replacingOccurrences(of: "{n}", with: String(n))
        }
        return body
    }
    static let counterRestart: TimeInterval = 300
    private struct Count: Codable { var n: Int; var at: Double }
    static let countersFile = userRoot.appendingPathComponent("counters.json")
    private static func loadCounters() -> [String: Count] {
        (try? Data(contentsOf: countersFile)).flatMap { try? JSONDecoder().decode([String: Count].self, from: $0) } ?? [:]
    }
    private static func saveCounters(_ c: [String: Count]) {
        try? FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: countersFile) }
    }
    // The count so far, while it's still running (0 once five quiet minutes have passed).
    func counter(_ name: String) -> Int {
        guard let c = Self.loadCounters()[name], Date.now.timeIntervalSince1970 - c.at < Self.counterRestart else { return 0 }
        return c.n
    }
    func resetCounter(_ name: String) { var c = Self.loadCounters(); c[name] = nil; Self.saveCounters(c) }

    // A lens name from an abbreviation, when you didn't give one: ";ss" → "ss".
    static func name(from abbrev: String) -> String {
        abbrev.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    func delete(_ lens: Lens) {
        guard !lens.builtIn else { return }
        try? FileManager.default.removeItem(at: lens.url)
    }
}

extension LensStore {
    // Claude's File > New Session in New Window, then the lens lands in the new window's message box.
    @MainActor
    func openInNewWindow(_ name: String) {
        guard CommandsModel.run(title: "New Session in New Window") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if let text = self.expansion(name) { Paster.pasteIntoClaude(text) } }
    }
}

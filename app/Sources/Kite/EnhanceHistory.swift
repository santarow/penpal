import AppKit

// Recent asks in Enhance (#323, Jason: "perhaps allow the user to save the history of their preprompts?"). Each ask is
// kept with its notes, pictures and enhanced prompt in Penpal's own folder (enhance/history/<when>/), when you enhance
// it and when you send it; the Recent menu in the window's title bar opens one again, ready to edit or send. Asks from
// before this come from Enhance's own runs: the words and the enhanced prompt, not the pictures (a run kept them as one
// sheet). Clear Recent moves the kept asks to the Trash.
@MainActor
enum EnhanceHistory {
    static let folder = Kite.home.appendingPathComponent("enhance/history")
    static let clearedFile = Kite.home.appendingPathComponent("enhance/cleared.txt")
    static let runs = Kite.home.appendingPathComponent("agents/enhance/runs")
    struct Entry: Codable { var ask: String; var notes: [String]; var result: String; var at: Date; var sent: Bool }
    struct Item { let id: String; let title: String; let at: Date; let fromRun: Bool }

    static func stamp(_ d: Date = .now) -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: d) }
    static func date(_ id: String) -> Date? { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.date(from: String(id.prefix(15))) }

    // What's in the window now, kept (the same entry until it's sent or another is opened).
    static func save(_ m: EnhanceModel, sent: Bool = false) {
        let fm = FileManager.default
        guard !m.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !m.result.isEmpty || !m.shots.isEmpty else { return }
        let id = m.entry ?? stamp()
        m.entry = id
        let dir = folder.appendingPathComponent(id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix("picture-") { try? fm.removeItem(at: dir.appendingPathComponent(f)) }
        for (i, s) in m.shots.enumerated() { try? s.png.write(to: dir.appendingPathComponent("picture-\(i + 1).png")) }
        let was = (try? Data(contentsOf: dir.appendingPathComponent("entry.json"))).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        let e = Entry(ask: m.draft, notes: m.shots.map(\.note), result: m.result, at: .now, sent: sent || was?.sent == true)
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: dir.appendingPathComponent("entry.json")) }
    }

    // The newest first: kept asks, then Enhance's runs from before the first one was kept (and after Clear Recent).
    static func recent(limit: Int = 20) -> [Item] {
        let fm = FileManager.default
        let kept = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { date($0) != nil }.sorted(by: >)
        let cleared = (try? String(contentsOf: clearedFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstKept = kept.last ?? "99999999-999999"
        var items: [Item] = kept.compactMap { id in
            guard let e = (try? Data(contentsOf: folder.appendingPathComponent("\(id)/entry.json"))).flatMap({ try? JSONDecoder().decode(Entry.self, from: $0) })
            else { return nil }
            return Item(id: id, title: title(e.ask.isEmpty ? e.result : e.ask), at: date(id) ?? e.at, fromRun: false)
        }
        for id in ((try? fm.contentsOfDirectory(atPath: runs.path)) ?? []).sorted(by: >) where id < firstKept && id > cleared {
            guard items.count < limit + kept.count, let at = date(id), let (ask, _) = run(id), !ask.isEmpty else { continue }
            items.append(Item(id: id, title: title(ask), at: at, fromRun: true))
        }
        return Array(items.sorted { $0.at > $1.at }.prefix(limit))
    }

    // A run's ask and notes, from what Enhance sent it (<ask>…</ask>, <notes>…</notes>).
    static func run(_ id: String) -> (ask: String, notes: [String])? {
        guard let text = try? String(contentsOf: runs.appendingPathComponent("\(id)/input.md"), encoding: .utf8) else { return nil }
        func between(_ a: String, _ b: String) -> String? {
            guard let r = text.range(of: a), let e = text.range(of: b, range: r.upperBound..<text.endIndex) else { return nil }
            return String(text[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let notes = (between("<notes>", "</notes>") ?? "").split(separator: "\n").map {
            String($0).replacingOccurrences(of: #"^🖼 \d+:\s*"#, with: "", options: .regularExpression)
        }
        return (between("<ask>", "</ask>") ?? "", notes)
    }

    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 60 ? String(line.prefix(57)) + "…" : (line.isEmpty ? "(no words)" : line)
    }
    static func when(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Clock.locale
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(d) ? (Clock.uses24 ? "HH:mm" : "h:mm a") : "MMM d")
        return (Calendar.current.isDateInToday(d) ? "Today " : "") + f.string(from: d)
    }

    // Opens one in the window. What was there is kept first, so nothing is lost by switching.
    static func open(_ item: Item, into m: EnhanceModel) {
        if m.entry != item.id { save(m) }
        m.problem = nil; m.note = nil; m.expanded = nil
        if item.fromRun {
            let (ask, notes) = run(item.id) ?? ("", [])
            m.draft = ask
            m.result = (try? String(contentsOf: runs.appendingPathComponent("\(item.id)/result.md"), encoding: .utf8)).map(Enhance.unwrap) ?? ""
            m.shots = []
            m.entry = nil
            if !notes.isEmpty { m.note = "This ask had \(notes.count) picture\(notes.count == 1 ? "" : "s"), from before pictures were kept: take them again with Highlight." }
        } else {
            let dir = folder.appendingPathComponent(item.id)
            guard let e = (try? Data(contentsOf: dir.appendingPathComponent("entry.json"))).flatMap({ try? JSONDecoder().decode(Entry.self, from: $0) }) else { return }
            m.draft = e.ask; m.result = e.result
            m.shots = e.notes.indices.compactMap { i in
                (try? Data(contentsOf: dir.appendingPathComponent("picture-\(i + 1).png"))).map { EnhanceShot(png: $0, note: e.notes[i]) }
            }
            m.entry = item.id
        }
        Log.line("enhance: opened a recent ask (\(item.fromRun ? "from a run" : "kept"))")
    }

    // Clear Recent: the kept asks to the Trash (Finder can put them back), and older runs no longer listed.
    static func clear() {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { try? fm.trashItem(at: folder, resultingItemURL: nil) }
        try? fm.createDirectory(at: clearedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (stamp() + "\n").write(to: clearedFile, atomically: true, encoding: .utf8)
        Log.line("enhance: recent asks cleared")
    }

    // The title bar's Recent menu.
    static func menu() -> NSMenu {
        let menu = NSMenu()
        let items = recent()
        if items.isEmpty { menu.addItem(withTitle: "No recent asks", action: nil, keyEquivalent: "").isEnabled = false }
        for it in items {
            let mi = NSMenuItem(title: it.title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            mi.target = MenuTarget.shared
            mi.representedObject = it.id
            let a = NSMutableAttributedString(string: it.title + "  ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            a.append(NSAttributedString(string: when(it.at), attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
            mi.attributedTitle = a
            menu.addItem(mi)
        }
        if !items.isEmpty {
            menu.addItem(.separator())
            let c = NSMenuItem(title: "Clear Recent", action: #selector(MenuTarget.clear), keyEquivalent: "")
            c.target = MenuTarget.shared
            menu.addItem(c)
        }
        return menu
    }
    @MainActor final class MenuTarget: NSObject {
        static let shared = MenuTarget()
        @objc func pick(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let it = EnhanceHistory.recent(limit: 200).first(where: { $0.id == id }) else { return }
            EnhanceHistory.open(it, into: Enhance.model)
        }
        @objc func clear() { EnhanceHistory.clear() }
        @objc func show(_ sender: NSButton) {
            EnhanceHistory.menu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }
}

// --enhance-recent-check <out.png> (#323): Recent, checked. Your real list is only read and counted (nothing printed of
// what you wrote); the run that didn't send on 2026-10-08 opens with its words and prompt; and save, list and open are
// tried on a spare folder's copy of the model. Then the window's title bar drawn, with Recent beside Fold.
extension EnhanceHistory {
    static func check(out: String) {
        var ok = true
        func check(_ what: String, _ pass: Bool) { print("\(pass ? "ok  " : "FAIL") \(what)"); if !pass { ok = false } }
        let list = recent()
        print("recent asks listed: \(list.count) (\(list.filter(\.fromRun).count) from runs)")
        check("at most 20, newest first", list.count <= 20 && zip(list, list.dropFirst()).allSatisfy { $0.at >= $1.at })
        if let lost = recent(limit: 200).first(where: { $0.id == "20261008-080629" }) {
            let m = EnhanceModel()
            open(lost, into: m)
            check("the ask that didn't send (08:06) opens with its words and its enhanced prompt", !m.draft.isEmpty && !m.result.isEmpty && m.entry == nil)
            check("…and says its 4 pictures weren't kept", m.note?.contains("4 pictures") == true)
        } else { print("(the 08:06 run isn't here)") }
        // Save, list, open, on a model of its own: written to the real folder, then removed again.
        let m = EnhanceModel()
        m.draft = "Recent check \(UUID().uuidString.prefix(6))\nsecond line"; m.result = "<prompt>x</prompt>"
        m.shots = [EnhanceShot(png: NSImage(size: NSSize(width: 4, height: 4)).tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data(), note: "a note")]
        save(m)
        let id = m.entry ?? ""
        let found = recent().first { $0.id == id }
        check("a saved ask is listed first, by its first line", found != nil && recent().first?.id == id && found?.title == m.draft.split(separator: "\n").first.map(String.init))
        let back = EnhanceModel()
        if let found { open(found, into: back) }
        check("it opens with its words, prompt, picture and note", back.draft == m.draft && back.result == m.result && back.shots.count == 1 && back.shots.first?.note == "a note")
        save(m, sent: true); save(m)
        let e = (try? Data(contentsOf: folder.appendingPathComponent("\(id)/entry.json"))).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        check("one entry per ask, sent stays sent", e?.sent == true && ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 == id }.count == 1)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id))
        // The title bar.
        Enhance.open()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let w = NSApp.windows.first(where: { $0.title == "Enhance" }), let frame = w.contentView?.superview,
           let bmp = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: bmp)
            try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            w.orderOut(nil)
        }
        print(ok ? "all passed" : "SOME FAILED")
        exit(ok ? 0 : 1)
    }
}

import AppKit
import ApplicationServices

// Puts text into whatever box has focus by pasting it, then restores the clipboard.
// Never presses Enter: the user sends the message.
@MainActor
enum Paster {
    // A snippet (#319): only into the app it was typed in, still in front, and in Claude only into its message box.
    // Otherwise nothing is deleted or typed.
    static func paste(_ text: String, deleting count: Int = 0, into pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return Log.line("snippet: its app isn't in front, nothing typed") }
        guard let f = focusedElement(pid), isPrompt(f), showing(f, pid) else { return Log.line("snippet: not in Claude's message box (\(describe(focusedElement(pid)))), nothing typed") }
        paste(deleting: count) { $0.setString(text, forType: .string) }
    }

    private static func paste(deleting count: Int = 0, write: (NSPasteboard) -> Void) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count { press(51, source) }  // delete

        let board = NSPasteboard.general
        let saved = save(board)
        board.clearContents()
        write(board)
        let ours = board.changeCount
        press(9, source, flags: .maskCommand)  // cmd-V
        restore(board, saved, ifStill: ours)
    }

    // Where lens buttons and screenshots go: Claude's message box (default), or the app in front.
    enum Target: String, CaseIterable {
        case claude, chat, front, clipboard
        var label: String {
            switch self {
            case .claude: Flavor.current.has(.chat) ? "Claude's message box (\(AppName.shown)'s Chat if Claude is closed)" : "Claude's message box"
            case .chat: "\(AppName.shown)'s Chat"
            case .front: "The app in front"
            case .clipboard: "Clipboard (you press ⌘V where you want it)"
            }
        }
    }
    static let targetKey = "pasteTarget"
    static var target: Target { Target(rawValue: UserDefaults.standard.string(forKey: targetKey) ?? "") ?? .claude }

    static func pasteIntoClaude(_ text: String) {
        if target == .clipboard { return copy("text") { $0.setString(text, forType: .string) } }
        deliver("text") { $0.setString(text, forType: .string) }
    }

    // PNG plus TIFF, so any app that takes pasted images finds a type it reads.
    // The same picture twice within 2 s is one action arriving twice: it's pasted once.
    private static var lastImage: (hash: Int, at: Date)?
    static func pasteImageIntoClaude(_ png: Data) {
        let hash = png.hashValue
        if let last = lastImage, last.hash == hash, Date.now.timeIntervalSince(last.at) < 2 {
            return Log.line("same image again within 2 s: not pasted twice")
        }
        lastImage = (hash, .now)
        // The app's Chat takes it when chosen, or when Claude isn't running to receive it. Penpal has no Chat (#271):
        // with Claude closed, the picture waits on the clipboard.
        if Flavor.current.has(.chat), target == .chat || (target == .claude && claudeApp == nil) {
            return AgentStore.shared.attach(png)
        }
        if !Flavor.current.has(.chat), target == .claude, claudeApp == nil {
            return copy("image") { board in
                board.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
            }
        }
        let tiff = NSImage(data: png)?.tiffRepresentation
        if target == .clipboard {
            return copy("image") { board in
                board.setData(png, forType: .png)
                if let tiff { board.setData(tiff, forType: .tiff) }
            }
        }
        deliver("image", label: numberPictures && claudeApp != nil && target == .claude ? pictureLabel() : nil) { board in
            board.setData(png, forType: .png)
            if let tiff { board.setData(tiff, forType: .tiff) }
        }
    }

    // Leaves it on the clipboard (not restored afterwards), with a soft sound so you know it's there.
    private static func copy(_ what: String, write: (NSPasteboard) -> Void) {
        let board = NSPasteboard.general
        board.clearContents()
        write(board)
        NSSound(named: "Pop")?.play()
        Log.line("copied \(what) to the clipboard")
    }

    // Presses the app's own Edit > Paste through Accessibility: a fake ⌘V right after
    // a ⌃⌥ drag was ignored most of the time. Falls back to ⌘V if the menu isn't found.
    private static func deliver(_ what: String, label: String? = nil, write: @escaping (NSPasteboard) -> Void) {
        // A labelled picture checks that its paste landed, so it needs less of a pause once Claude is in front.
        pickTarget(pause: label == nil ? 0.15 : 0.05) { app in
            guard let app else { return }
            // Without Device Control (Accessibility) macOS drops a pasted ⌘V: leave it on the clipboard
            // and say so, instead of a paste that silently doesn't happen.
            guard AXIsProcessTrusted() else {
                let board = NSPasteboard.general
                board.clearContents(); write(board)
                NSSound(named: "Pop")?.play()
                Notice.show("Copied. Press ⌘V to paste it.")
                return Log.line("copied \(what) (no \(Permissions.controlName) to paste it)")
            }
            let pid = app.processIdentifier
            let isClaude = Expander.claudeApps.contains(app.bundleIdentifier ?? "")
            Log.line("paste \(what) into \(app.bundleIdentifier ?? "?")")
            let board = NSPasteboard.general
            let saved = save(board)
            var wait = 0.0
            if isClaude {
                Log.line("focus in Claude: \(describe(focusedElement(pid)))")
                let refocused = focusPrompt(pid)
                Log.line("prompt box: \(refocused)")
                if refocused != "already focused" { wait = 0.1 }  // let the web view move focus first
            }
            @MainActor func pasteNow() -> Bool { pasteInto(pid, claude: isClaude) }
            @MainActor func pasteIt() {
                board.clearContents(); write(board)
                let ours = board.changeCount
                if pasteNow() { restore(board, saved, ifStill: ours) } else { leftOnClipboard(what, claude: isClaude) }
            }
            guard let label else {
                return DispatchQueue.main.asyncAfter(deadline: .now() + wait) { MainActor.assumeIsolated { pasteIt(); took(what) } }
            }
            // The label first ("🖼 2"), then the picture, so your words can point at it. No fixed waits:
            // the picture goes in as soon as the box shows the label (Claude has read the clipboard by then),
            // and a label that didn't land (the box not ready yet) is pasted once more.
            let before = isClaude ? promptText(pid) : nil
            @MainActor func pasteLabel(try n: Int) {
                board.clearContents(); board.setString(label, forType: .string)
                guard pasteNow() else { return pasteIt() }  // nowhere safe to type: the picture waits on the clipboard
                let sent = Date.now
                @MainActor func check() {
                    let gone = Date.now.timeIntervalSince(sent)
                    if let now = promptText(pid), now != before {
                        Log.line("label in after \(Int(gone * 1000))ms")
                        pasteIt(); took("label + image")
                    } else if gone < 0.4 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { check() } }
                    } else if n == 1 {
                        Log.line("label not in after 400ms, pasting it again (\(focusPrompt(pid)))")
                        pasteLabel(try: 2)
                    } else {
                        Log.line("label still not in, pasting the picture anyway")
                        pasteIt(); took("image")
                    }
                }
                // Claude's box can't be read: the old fixed gap.
                if before == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { pasteIt(); took("label + image (fixed gap)") } } }
                else { check() }
            }
            // Unreadable box: keep the settle that fixed the lost first label.
            DispatchQueue.main.asyncAfter(deadline: .now() + (before == nil ? max(wait, 0.35) : wait)) {
                MainActor.assumeIsolated { pasteLabel(try: 1) }
            }
        }
    }

    // When a capture started (mouse-up), so the log shows how long it took to land in Claude.
    static var startedAt: Date?
    private static func took(_ what: String) {
        guard let t = startedAt else { return }
        startedAt = nil
        guard Date.now.timeIntervalSince(t) < 10 else { return }  // a capture that went to Ask, not here
        Log.line("\(what) pasted \(Int(Date.now.timeIntervalSince(t) * 1000))ms after mouse-up")
    }

    // The text in Claude's message box, to see that a paste landed. Nil when it can't be read.
    private static func promptText(_ pid: pid_t) -> String? {
        guard let box = lastPrompt ?? focusedElement(pid) else { return nil }
        return attr(box, "AXValue") as? String
    }

    // Numbered pictures (Settings › Screenshots): "🖼 1", "🖼 2"… with new lines between them (1 unless you
    // pick 0–5, #248, #249; 0 puts the next right after the last), counting again after five quiet minutes
    // (the next message), like a lens's {n}.
    static let numberKey = "screenshots.number"
    static var numberPictures: Bool { UserDefaults.standard.object(forKey: numberKey) as? Bool ?? true }
    static let linesKey = "screenshots.lines"
    static let linesDefault = 1  // #249, Jason: "change default to 1 enter between"
    static var linesBetween: Int {
        let d = UserDefaults.standard
        return min(max(d.object(forKey: linesKey) == nil ? linesDefault : d.integer(forKey: linesKey), 0), 5)
    }
    static func continuePictures(after n: Int) {
        UserDefaults.standard.set(n, forKey: "pictures.n"); UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "pictures.at")
    }
    static func resetPictures() { UserDefaults.standard.set(0, forKey: "pictures.at"); Log.line("pictures: numbering starts over") }
    static func pictureLabel() -> String {
        let d = UserDefaults.standard, now = Date.now.timeIntervalSince1970
        let n = now - d.double(forKey: "pictures.at") < 300 ? d.integer(forKey: "pictures.n") + 1 : 1
        d.set(n, forKey: "pictures.n"); d.set(now, forKey: "pictures.at")
        return (n == 1 ? "" : String(repeating: "\n", count: linesBetween)) + "\u{1F5BC} \(n) "   // U+1F5BC FRAME WITH PICTURE
    }

    // Pictures and words into Claude's box in one pass: picture, picture, …, then the words (Jason, 2026-10-06:
    // "YOU CLEARLY DID IT CORRECTLY IN 1 PASS AND FAST TOO the SECOND TIME"; the one-by-one run put 2 pictures and
    // the words in 0.22 s, while the bulk paste of files and its 3 s wait to see them had doubled them). Claude
    // comes forward once, the box gets focus once, the clipboard comes back once. Nothing is pasted twice.
    // How a send went (#323, Jason: "i made a long pre-prompt, but it was not sent to claude"): in only when the words are
    // seen in the box Claude shows, and the box grew by the pictures. Never "sent" on a guess.
    struct Sent { let ok: Bool; let why: String; let note: String }
    static func pastePicturesAndText(_ pngs: [Data], text: String, done: @escaping @MainActor (Sent) -> Void = { _ in }) {
        let started = Date.now
        pickTarget(pause: 0.05) { app in
            guard let app else { return done(Sent(ok: false, why: "Claude isn't running.", note: "")) }
            guard AXIsProcessTrusted() else { return done(Sent(ok: false, why: "\(AppName.shown) needs \(Permissions.controlName) to paste.", note: "")) }
            let pid = app.processIdentifier, board = NSPasteboard.general, saved = save(board)
            let isClaude = Expander.claudeApps.contains(app.bundleIdentifier ?? "")
            if isClaude { Log.line("send: prompt box \(focusPrompt(pid))") }
            guard !isClaude || (focusedElement(pid).map { isPrompt($0) && showing($0, pid) } ?? false) else {
                Log.line("send: Claude's message box not found, nothing typed")
                return done(Sent(ok: false, why: "Couldn't find Claude's message box.", note: ""))
            }
            let wordsBefore = isClaude ? promptText(pid) ?? "" : "", sizeBefore = isClaude ? composerSize(pid) : nil
            @MainActor func paste(_ write: (NSPasteboard) -> Void) {
                board.clearContents(); write(board)
                _ = pasteInto(pid, claude: isClaude)
            }
            var had: String?
            let io = SendIO(
                pasteOne: { i in paste { b in
                    b.setData(pngs[i], forType: .png)
                    if let tiff = NSImage(data: pngs[i])?.tiffRepresentation { b.setData(tiff, forType: .tiff) }
                } },
                pasteText: { had = promptText(pid); paste { $0.setString(text, forType: .string) } },
                size: { composerSize(pid) },
                textLanded: { promptText(pid) != had })
            runSend(pictures: pngs.count, text: !text.isEmpty, io: io) { note in
                let ms = Int(Date.now.timeIntervalSince(started) * 1000)
                Log.line("send: \(pngs.count) pictures + \(text.count) characters in \(ms)ms, one pass\(note)")
                // Checked in the box Claude shows: the words' start is in it, and it holds a part per picture more than before.
                var why = ""
                if isClaude {
                    let flat = { (t: String) in t.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                    let head = String(flat(text).prefix(60))
                    if !text.isEmpty, let now = promptText(pid), now == wordsBefore || !flat(now).contains(head) {  // unreadable: can't tell
                        why = "The words didn't show up in Claude's message box."
                    } else if !pngs.isEmpty, let a = sizeBefore, let b = composerSize(pid), b <= a {
                        why = "The pictures didn't show up in Claude's message box."
                    }
                }
                if why.isEmpty { restore(board, saved, ifStill: board.changeCount) }
                Log.line(why.isEmpty ? "send: seen in Claude's message box" : "send: NOT sent: \(why)")
                done(Sent(ok: why.isEmpty, why: why, note: "\(ms)ms\(note)"))
            }
        }
    }

    // What Send does with Claude, so a test can play Claude (--send-sim).
    struct SendIO {
        var pasteOne: @MainActor (Int) -> Void      // one picture
        var pasteText: @MainActor () -> Void        // all the words
        var size: @MainActor () -> Int?             // how much is in Claude's box and tray; nil when it can't be read
        var textLanded: @MainActor () -> Bool
    }

    // One pass, in order: each picture, then the words. Between them only a small handoff: the next paste goes as soon
    // as Claude's box shows the last one (usually tens of milliseconds), or after `handoff` seconds at most, so Claude has
    // taken it off the clipboard before the next one replaces it. Nothing waits longer, nothing is pasted again.
    static func runSend(pictures n: Int, text: Bool, io: SendIO, handoff: Double = 0.3, finish: @escaping @MainActor (String) -> Void) {
        @MainActor func waitFor(_ limit: Double, _ landed: @escaping @MainActor () -> Bool, _ then: @escaping @MainActor (Bool) -> Void) {
            let t0 = Date.now
            @MainActor func check() {
                if landed() { return then(true) }
                if Date.now.timeIntervalSince(t0) > limit { return then(false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { check() } }
            }
            check()
        }
        var unseen = 0
        @MainActor func one(_ i: Int) {
            guard i < n else {
                let note = unseen == 0 ? "" : ", \(unseen) of \(n) pictures not seen landing (went on after \(handoff) s)"
                guard text else { return finish(note) }
                io.pasteText()
                return waitFor(1.0, io.textLanded) { ok in finish(note + (ok ? "" : ", words not seen landing")) }
            }
            let had = io.size()
            io.pasteOne(i)
            waitFor(handoff, { (io.size()).map { now in had.map { now > $0 } ?? false } ?? false }) { seen in
                if !seen { unseen += 1 }
                one(i + 1)
            }
        }
        one(0)
    }

    // How much is in Claude's message box and the tray above it: the number of things under the box's
    // container. A picture landing adds some. Nil when the box can't be read.
    private static func composerSize(_ pid: pid_t) -> Int? {
        guard let box = lastPrompt ?? focusedElement(pid), var area = attr(box, "AXParent").map({ $0 as! AXUIElement }) else { return nil }
        for _ in 0..<2 { if let up = attr(area, "AXParent") { area = up as! AXUIElement } }  // up to the composer around box and tray
        var queue = [area], n = 0
        while !queue.isEmpty, n < 3000 {
            let e = queue.removeFirst(); n += 1
            queue += (attr(e, "AXChildren") as? [AXUIElement]) ?? []
        }
        return n
    }

    // The app to paste into. For Claude: bring it forward the way a Dock click does
    // (a plain activate() from a background app is often ignored, and the paste then
    // went to YouTube), and wait until it really is in front.
    private static func pickTarget(pause: Double = 0.15, _ then: @escaping @MainActor (NSRunningApplication?) -> Void) {
        let front = NSWorkspace.shared.frontmostApplication
        if target != .claude {  // .chat never gets here: text goes to the front app
            // Penpal itself in front (a click on its dock, #269): never into Penpal; the app before it comes back first.
            if front == NSRunningApplication.current, let other = OtherApp.last, !other.isTerminated {
                other.activate()
                return waitUntilFront(other, since: .now, pause: pause, then)
            }
            return then(front)
        }
        if let front, Expander.claudeApps.contains(front.bundleIdentifier ?? "") { return then(front) }
        guard let claude = claudeApp else {
            Log.line("Claude not running, nothing pasted")
            return then(nil)
        }
        Log.line("bringing Claude forward (front was \(front?.bundleIdentifier ?? "?"))")
        if let url = claude.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        } else {
            claude.activate()
        }
        waitUntilFront(claude, since: .now, pause: pause, then)
    }

    private static var claudeApp: NSRunningApplication? {
        Expander.claudeApps.lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first
    }

    private static func waitUntilFront(_ app: NSRunningApplication, since: Date, pause: Double,
                                       _ then: @escaping @MainActor (NSRunningApplication?) -> Void) {
        let waited = Date.now.timeIntervalSince(since)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier || waited > 2 {
            Log.line("Claude \(waited > 2 ? "still not in front after 2 s, pasting anyway" : "in front after \(Int(waited * 1000))ms")")
            // A short pause once it is in front, so its window is ready for focus and paste.
            DispatchQueue.main.asyncAfter(deadline: .now() + pause) { then(app) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitUntilFront(app, since: since, pause: pause, then) }
    }

    // A click on the chat moves focus off the message box, and Edit > Paste then lands nowhere.
    // Put focus back on it: the box from the last paste if it still exists, else search the window.
    private static var lastPrompt: AXUIElement?

    // Only a box Claude shows now (#323): the last one found can be a chat's, hidden behind a Code tab session, and the
    // send went there and was called sent. So it's looked for each time, and never reused unseen.
    private static func focusPrompt(_ pid: pid_t) -> String {
        if let now = focusedElement(pid), isPrompt(now), showing(now, pid) {
            lastPrompt = now
            return "already focused"
        }
        lastPrompt = nil
        guard let window = attr(AXUIElementCreateApplication(pid), "AXFocusedWindow") else { return "no window" }
        guard let box = findPrompt(in: window as! AXUIElement, pid) else { return "not found" }
        lastPrompt = box
        return AXUIElementSetAttributeValue(box, "AXFocused" as CFString, kCFBooleanTrue) == .success
            ? "found and focused" : "found, could not focus"
    }

    // Breadth-first, skipping the message list, capped so a long chat can't stall it. Only Claude's message box:
    // never the first text area seen, which can be a file open in the Code tab (#319).
    private static func findPrompt(in root: AXUIElement, _ pid: pid_t) -> AXUIElement? {
        var queue = [root], seen = 0
        while !queue.isEmpty, seen < 5000 {
            let e = queue.removeFirst()
            seen += 1
            if isPrompt(e), showing(e, pid) { return e }
            if attr(e, "AXDescription") as? String == "Chat messages" { continue }
            queue += (attr(e, "AXChildren") as? [AXUIElement]) ?? []
        }
        return nil
    }

    // Claude's message box: a text area named as the prompt ("Prompt" in a chat, "Write your prompt to Claude" in Code).
    // A file's editor ("File contents") or an unnamed box isn't it (#319: "🖼 1 " went into a .sql file open in Claude).
    static func isPrompt(_ e: AXUIElement) -> Bool {
        guard attr(e, "AXRole") as? String == "AXTextArea" else { return false }
        return ["AXDescription", "AXTitle", "AXPlaceholderValue"].contains { (attr(e, $0) as? String)?.lowercased().contains("prompt") == true }
    }

    // On screen now: a real size, inside the window in front, and what's at its middle is it (or something in it).
    static func showing(_ e: AXUIElement, _ pid: pid_t) -> Bool {
        func frame(_ x: AXUIElement) -> CGRect? {
            guard let p = attr(x, "AXPosition"), let z = attr(x, "AXSize") else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(z as! AXValue, .cgSize, &sz)
            return CGRect(origin: pt, size: sz)
        }
        guard let f = frame(e), f.width > 20, f.height > 10 else { return false }
        let app = AXUIElementCreateApplication(pid)
        if let w = attr(app, "AXFocusedWindow"), let wf = frame(w as! AXUIElement), !wf.intersects(f) { return false }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(f.midX), Float(f.midY), &hit) == .success, var h = hit else { return true }  // can't tell: the frame says shown
        for _ in 0..<12 {
            if CFEqual(h, e) { return true }
            guard let up = attr(h, "AXParent") else { break }
            h = up as! AXUIElement
        }
        return false
    }

    // Pastes only where it was meant to go (#319): in Claude only its message box; anywhere only the chosen app, by its own
    // Edit > Paste, or ⌘V while that app is in front. False when it can't: nothing is typed anywhere.
    private static func pasteInto(_ pid: pid_t, claude: Bool) -> Bool {
        if claude, !(focusedElement(pid).map { isPrompt($0) && showing($0, pid) } ?? false) {
            Log.line("paste: focus isn't Claude's message box (\(describe(focusedElement(pid)))), nothing typed")
            return false
        }
        if pressMenuPaste(pid) { Log.line("pressed Edit > Paste"); return true }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            Log.line("paste: the app isn't in front, no ⌘V, nothing typed")
            return false
        }
        Log.line("no Paste menu item, sent ⌘V")
        press(9, CGEventSource(stateID: .combinedSessionState), flags: .maskCommand)
        return true
    }
    // --paste-target-check (#319): where a paste into Claude would go now, read-only (nothing focused, typed or clicked).
    static func targetCheck() {
        guard let claude = claudeApp else { print("Claude isn't running"); exit(1) }
        let pid = claude.processIdentifier
        let focus = focusedElement(pid)
        print("focus in Claude: \(describe(focus)) -> \(focus.map { isPrompt($0) && showing($0, pid) } == true ? "its message box: would paste" : "not its message box showing: would look for it")")
        if let w = attr(AXUIElementCreateApplication(pid), "AXFocusedWindow") {
            // Every box named as a prompt in the window, and what's at its middle (roles and names only).
            var queue = [w as! AXUIElement], seen = 0
            while !queue.isEmpty, seen < 5000 {
                let e = queue.removeFirst(); seen += 1
                if isPrompt(e), let p = attr(e, "AXPosition"), let z = attr(e, "AXSize") {
                    var pt = CGPoint.zero, sz = CGSize.zero
                    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(z as! AXValue, .cgSize, &sz)
                    var hit: AXUIElement?
                    let r = AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(pt.x + sz.width / 2), Float(pt.y + sz.height / 2), &hit)
                    print("  prompt box \(describe(e)) at \(Int(pt.x)),\(Int(pt.y)) \(Int(sz.width))x\(Int(sz.height)): showing=\(showing(e, pid)); at its middle (\(r.rawValue)): \(describe(hit))")
                }
                queue += (attr(e, "AXChildren") as? [AXUIElement]) ?? []
            }
            let box = findPrompt(in: w as! AXUIElement, pid)
            print("message box in its window: \(box.map(describe) ?? "none found: the picture would wait on the clipboard")")
        }
        exit(0)
    }
    // When it couldn't paste: it stays on the clipboard (not put back), and you're told.
    private static func leftOnClipboard(_ what: String, claude: Bool) {
        NSSound(named: "Pop")?.play()
        Notice.show(claude ? "Copied. Click in Claude's message box and press ⌘V." : "Copied. Press ⌘V where you want it.")
        Log.line("\(what) left on the clipboard: nowhere safe to paste")
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(e, name as CFString, &value)
        return value
    }

    private static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        attr(AXUIElementCreateApplication(pid), "AXFocusedUIElement").map { $0 as! AXUIElement }
    }

    // The menu item whose shortcut is plain ⌘V, found by shortcut so any language works.
    private static func pressMenuPaste(_ pid: pid_t) -> Bool {
        func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = attr(app, "AXMenuBar") else { return false }
        for barItem in children(bar as! AXUIElement) {
            for menu in children(barItem) {
                for item in children(menu) where
                    (attr(item, "AXMenuItemCmdChar") as? String) == "V" &&
                    (attr(item, "AXMenuItemCmdModifiers") as? Int) == 0 {  // 0 = ⌘ alone
                    return AXUIElementPerformAction(item, "AXPress" as CFString) == .success
                }
            }
        }
        return false
    }

    // The kind of element (role, subrole, label), never its text.
    private static func describe(_ e: AXUIElement?) -> String {
        guard let e else { return "nothing" }
        return ["AXRole", "AXSubrole", "AXDescription"]
            .compactMap { (attr(e, $0) as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } }
            .joined(separator: " / ")
    }

    private static func save(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        }
    }

    // A second later, put back what was on the clipboard, unless the user copied something since.
    private static func restore(_ board: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]], ifStill ours: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard board.changeCount == ours else { return }
            board.clearContents()
            board.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }
    }

    private static func press(_ key: CGKeyCode, _ source: CGEventSource?, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

import AppKit
import ScreenCaptureKit
import SwiftUI

// Screen guide: "how do I turn on Night Shift?" (or instructions pasted from Claude). Kite reads the
// app you're in (a picture plus its buttons, menus and rows through Accessibility), the guide agent
// lists every step you can do on this screen, and Kite rings each one with its number and writes the
// steps out in red (#250, Jason: "circling ALL the things i need to do on a particular screen and
// label it like 1, 2, 3", "write out the steps in red on screen and after each step is done, cross
// them off"). You click them yourself; Kite never clicks. Each one is crossed off as you do it, and
// when they all are, it looks again, in the same session, for the next screen's steps.

struct GuideControl: @unchecked Sendable {  // AXUIElement is a thread-safe CF reference
    let n: Int
    let role: String
    let label: String
    let frame: CGRect  // Accessibility coordinates: points from the top-left of the main screen
    var element: AXUIElement? = nil  // to find it again when it moves or grows (#250, Nike's search box)
}

// One step on the screen: what to do, and the control it's on (nil when it isn't on screen).
struct GuideStep: Identifiable {
    // What crosses it off (#250, Jason: clicking the search bar crossed off "Type: onion ring" too):
    // a click in its ring, text typed into its box, or Return. Each only by its own action.
    enum Kind: String { case click, type, enter, see }  // see: a tour's part of the page, ringed to look at (#308)
    var id: Int        // its number, 1, 2, 3… counting on across screens (a step put in before others moves them on, #306)
    var say: String    // an answer to your question can reword it (#306)
    var target: CGRect?   // where its control is now: it follows the control when that moves or grows
    let role: String
    var control: Int? = nil  // the control's number in the list: steps on the same control go in order
    var kind = Kind.click
    var thenEnter = false  // "Type: …, then press Enter" as one step: crossed off on Return after typing
    var done = false
    var note: String?  // one short line under it: the answer to a question about this step (#306)

    // What to type, for Copy (#264, Jason: "allow me to copy the text here, since typing out address is a
    // hassle"): the text after "Type:" (the guide is told to say exactly what to type that way), out of its quotes,
    // without ", then press Enter" or "in the search box". None when the step doesn't say it that way.
    var value: String? {
        guard kind == .type else { return nil }
        let s = say.trimmingCharacters(in: .whitespaces)
        guard let colon = s.range(of: ":"),
              ["type", "enter", "paste"].contains(s[..<colon.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        var v = String(s[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        for tail in [#",?\s+(and\s+)?then\s+(press|hit)\s+(enter|return)\.?$"#, #",?\s+and\s+(press|hit)\s+(enter|return)\.?$"#,
                     #"\s+(in|into)\s+the\s+[\w\s]*?(box|field|bar)\.?$"#] {
            if let r = v.range(of: tail, options: [.regularExpression, .caseInsensitive]) { v.removeSubrange(r) }
        }
        for (o, c) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")] where v.count >= 2 && v.hasPrefix(o) && v.hasSuffix(c) {
            v = String(v.dropFirst().dropLast())
        }
        return v.isEmpty ? nil : v
    }

    // The guide says which ("do"); an older answer is read from its words.
    static func kind(_ say: String, given: String?) -> (Kind, Bool) {
        let s = say.lowercased().trimmingCharacters(in: .whitespaces)
        let enterWords = ["press enter", "press return", "hit enter", "hit return", "then enter", "and enter"]
        if let given, let k = Kind(rawValue: given) { return (k, k == .type && enterWords.contains { s.contains($0) }) }
        if s.hasPrefix("press enter") || s.hasPrefix("press return") || s.hasPrefix("hit enter") || s == "enter" { return (.enter, false) }
        if s.hasPrefix("type") || s.hasPrefix("enter ") || s.hasPrefix("paste") { return (.type, enterWords.contains { s.contains($0) }) }
        return (.click, false)
    }
}

// What you just did, in Accessibility coordinates (top-left of the main screen).
// text: what has focus is a text box. afterClick: it's the box that took focus right after a click step
// was done (a small search box that grows into a bigger one when clicked, #250 on nike.com).
enum GuideAct {
    case click(CGPoint)
    case typed(focus: CGRect?, text: Bool = false, afterClick: Bool = false)   // a character typed, into whatever has focus
    case returnKey(focus: CGRect?, text: Bool = false, afterClick: Bool = false)
}

@MainActor
final class GuideState: ObservableObject {
    enum Phase { case asking, looking, showing, done, failed }
    @Published var goal = ""
    @Published var phase = Phase.asking
    @Published var say = ""            // while looking, when done or failed: one line
    @Published var steps: [GuideStep] = []
    @Published var after = ""          // what comes once these are done ("a new page opens")
    var last = false                   // these steps finish the goal: no look after them
    @Published var moreOpen = false    // the ask box under the steps is open (the chat bubble, #306)
    @Published var answering = false   // a question about the steps is with the guide (#306)
    @Published var answer: String?     // what only you know, said plainly (#306)
    @Published var more = ""           // what you type there (#250, Jason: "a prompt button that expands a text box")
    @Published var minimized = false   // shrunk to a pill ("Guide · 2 left"); a click opens it again
    @Published var since = Date.now    // when this look started, for the seconds counter
    var placed: NSPoint?               // the panel's top-left where you dragged it, until the next look
    var count = 0                      // steps given so far, so the next screen's go on from there
    var appName = ""
    var runID: String?
    @Published var streaming = false   // steps still arriving: each gets its ring as it comes (#259)
    @Published var copied: Int?        // the step whose text was just copied, for a moment's "Copied" (#264)
    var copyHover: Int?                // for --guide-sim's picture: the copy icon drawn as if the mouse were on it
}

@MainActor
enum Guide {
    static var dryRun = false  // --time-guide: the real steps and timing, nothing drawn on screen
    private static var state = GuideState()
    private static var askPanel: NSPanel?
    private static var bubble: NSPanel?
    private static var rings: [NSPanel] = []
    private static var watch: Timer?
    private static var controls: [GuideControl] = []
    // The last app you used that isn't Kite, so Guide knows what you meant even with a Kite window in front.
    private static var lastApp: NSRunningApplication?
    private static let watcher: Any = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let id = app?.processIdentifier
        MainActor.assumeIsolated {
            if let id, id != ProcessInfo.processInfo.processIdentifier {
                Guide.lastApp = NSRunningApplication(processIdentifier: id)
            }
        }
    }
    static func watchApps() { _ = watcher }

    // Dock button or menu: ask what to do in the app that's in front.
    static func start() {
        close()
        WarmAgent.guide.prepare()  // a claude ready while you type the goal (#254)
        let app = frontApp()
        state = GuideState()
        state.appName = app?.localizedName ?? "this app"
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 90), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.level = .floating
        p.backgroundColor = .clear
        p.hasShadow = true
        let host = NSHostingView(rootView: GuideAskView(state: state))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        let screen = NSScreen.main?.visibleFrame ?? .zero
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 60, width: size.width, height: size.height), display: true)
        p.makeKeyAndOrderFront(nil)
        askPanel = p
        if let app { prefetch(app.processIdentifier) }  // read the screen while you type (#259)
        Log.line("guide: open for \(state.appName)")
    }

    static func begin() {
        let goal = state.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        askPanel?.orderOut(nil)
        askPanel = nil
        look(first: true)
    }

    // ---------- Faster (#259, Jason: "is there a way we can make guide me MUCH faster?") ----------
    // The screen is read while you type the goal; the picture is small (1280 px, from ScreenCaptureKit, with
    // Penpal's own windows left out, so nothing has to hide); the answer comes one step per line and each
    // step gets its ring as it arrives; and a plain "click X" rings X from the control list at once.

    private struct Look { let pid: pid_t; let at: Date; let window: CGRect; let found: [GuideControl]; let png: Data?; let title: String? }
    private static var pre: Look?

    private static func prefetch(_ pid: pid_t) {
        let ours = ourFrames(), shown = shownArea(), t0 = Date.now
        pre = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let (window, inApp) = read(pid, under: ours)
            let found = inApp + aroundScreen(after: inApp.count, shown: shown)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let window, window.width > 10 else { return }
                snap(screenRect(around: window)) { png in
                    pre = Look(pid: pid, at: .now, window: window, found: found, png: png, title: windowTitle(pid))
                    Log.line("guide: screen read ahead in \(Int(Date.now.timeIntervalSince(t0) * 1000))ms (\(found.count) controls, picture \((png?.count ?? 0) / 1024) KB)")
                }
            } }
        }
    }

    // The read-ahead, if it's still the screen: same app, same window title and place, under a minute old.
    private static func freshPrefetch(_ pid: pid_t) -> Look? {
        guard let p = pre, p.pid == pid, Date.now.timeIntervalSince(p.at) < 60, windowTitle(pid) == p.title,
              let w = read(pid, under: [], windowOnly: true).0, abs(w.minX - p.window.minX) + abs(w.minY - p.window.minY) + abs(w.width - p.window.width) < 2
        else { return nil }
        return p
    }

    // The screen the window is on, small, without Penpal's windows. Falls back to screencapture.
    static func snap(_ rect: CGRect, width: Int = 1280, done: @escaping @MainActor (Data?) -> Void) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.max(by: { $0.frame.intersection(rect).width * $0.frame.intersection(rect).height
                                                               < $1.frame.intersection(rect).width * $1.frame.intersection(rect).height }) else { throw CancellationError() }
                let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = min(width, display.width * 2)
                cfg.height = Int(Double(cfg.width) * Double(display.height) / Double(display.width))
                cfg.showsCursor = false
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                done(NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]))
            } catch {
                Log.line("guide: ScreenCaptureKit failed (\(error.localizedDescription)); screencapture instead")
                capture(rect, done: done)
            }
        }
    }

    // "click X", "circle X", "find X", "open X", "where is X": X from the control list, ringed at once, before
    // Claude answers (it then confirms or adds steps). Only one clear match; anything else waits for Claude.
    static func instantSteps(_ goal: String, _ controls: [GuideControl]) -> [GuideControl] {
        var g = goal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for lead in ["please ", "can you ", "could you ", "help me ", "show me where ", "show me "] where g.hasPrefix(lead) { g.removeFirst(lead.count) }
        guard let m = g.range(of: #"^(click|press|tap|open|find|circle|where is|where's)( on)?( the)? "#, options: .regularExpression) else { return [] }
        var q = String(g[m.upperBound...])
        let place = q.contains("dock") ? "dockitem" : q.contains("menu bar") ? "menuextra" : nil  // where it is, if said
        var trimmed = true
        while trimmed {  // "the Penpal icon in the Dock" → "penpal"
            trimmed = false
            for tail in [" button", " icon", " app", " tab", " link", " session", " box", " field", " in the dock", " on the dock", " in the menu bar"] where q.hasSuffix(tail) {
                q.removeLast(tail.count); trimmed = true
            }
        }
        guard q.count >= 3, !q.hasPrefix("all ") else { return [] }
        let controls = controls.filter { $0.frame.width >= 16 && $0.frame.height >= 16 && (place == nil || $0.role == place) }
        func score(_ c: GuideControl) -> Int {
            let l = c.label.lowercased()
            return l == q ? 3 : l.hasPrefix(q) ? 2 : (l.contains(q) || (l.count >= 4 && q.contains(l))) ? 1 : 0
        }
        let best = controls.map { ($0, score($0)) }.filter { $0.1 > 0 }
        guard let top = best.map(\.1).max() else { return [] }
        let tops = best.filter { $0.1 == top }
        if tops.count == 1 { return [tops[0].0] }
        // The same name twice in the Dock or menu bar (an app pinned and recently used): the first is it.
        if place != nil, Set(tops.map { $0.0.label.lowercased() }).count == 1 { return [tops[0].0] }
        return []  // two different good matches: let Claude pick
    }

    // Next step: a fresh look at whatever app is in front now.
    static func next() {
        guard state.phase == .showing else { return }
        look(first: state.runID == nil)  // a retry before any answer starts fresh
    }

    // "Tell it more": not what you meant ("no, the icons in the Dock")? It looks again with your words, in
    // the same conversation, from any point (steps showing, done, or failed).
    static func tell() {
        let more = state.more.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !more.isEmpty else { return }
        state.more = ""
        state.moreOpen = false
        // With steps showing (#306, Jason: "hmm where do i find my policy url? and it accounts for that in steps"): the
        // answer folds into them. Before any, or after done or failed: it looks again with your words, as before.
        if state.phase == .showing, !state.steps.isEmpty, state.runID != nil { return askAbout(more) }
        Log.line("guide: told more")
        look(first: state.runID == nil, note: more)
    }

    // A question mid-way, sent with the goal, the steps (crossed-off ones marked) and a fresh look at the screen, in the
    // same conversation. The answer edits the steps (reword, put one in, a line under one) and never touches the done ones.
    static var lastQuestion = ""
    static func askAbout(_ q: String) {
        lastQuestion = q
        state.answering = true; state.answer = nil
        showBubble()
        Log.line("guide: asked about the steps")
        guard let app = frontApp() else { return answered(nil, "There's no app in front to look at.") }
        let pid = app.processIdentifier, ours = ourFrames(), shown = shownArea()
        DispatchQueue.global(qos: .userInitiated).async {
            let (window, inApp) = read(pid, under: ours)
            let found = inApp + aroundScreen(after: inApp.count, shown: shown)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard state.answering else { return }  // closed meanwhile
                guard let window, window.width > 10 else { return answered(nil, "\(AppName.shown) can't see a window in \(state.appName).") }
                controls = found
                let screen = screenRect(around: window)
                snap(screen) { png in
                    WarmAgent.start(.guide, questionText(q), png: png, context: describe(window, screen, found), follow: state.runID) { id in
                        guard let id else { return answered(nil, "\(AppName.shown) couldn't reach your Claude. Ask again.") }
                        state.runID = id
                        RunState.watch(agent: "guide", id: id) { run in
                            guard state.runID == id else { return }
                            WarmAgent.guide.prepare(resume: run.session)
                            answered(run.status == "done" ? run.result : nil, "The guide didn't answer that. Ask again.")
                        }
                    }
                }
            } }
        }
    }
    static func questionText(_ q: String) -> String {
        let list = state.steps.map { "\($0.id). \($0.done ? "(done) " : "")\($0.say)" }.joined(separator: "\n")
        return "Question: \(q)\nGoal: \(state.goal)\nThe steps so far:\n\(list)\nAnswer by changing these steps, not starting over."
    }
    // The answer into the steps: edits, a step put in, a line under one, or what only you know.
    static func answered(_ text: String?, _ otherwise: String) {
        state.answering = false
        guard let text else { state.answer = otherwise; return showBubble() }
        let objs = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any] }
        var fresh = false, changed = 0
        for o in objs {
            let say = o["say"] as? String, target = o["target"] as? Int, kind = o["do"] as? String
            if (o["edit"] != nil || o["insert_after"] != nil), let say, let made = madeUp(say) {  // never type a guess (#306)
                Log.line("guide: dropped a step that would type a made-up address")
                if state.answer == nil { state.answer = "Only you know the address for \(made). Type your own, or leave it empty if you don't have one." }
                changed += 1
            }
            else if let n = o["edit"] as? Int, let say { changed += reword(n, say: say, target: target, kind: kind) ? 1 : 0 }
            else if let n = o["insert_after"] as? Int, let say { changed += put(after: n, say: say, target: target, kind: kind) ? 1 : 0 }
            else if let n = o["note"] as? Int, let say, let i = state.steps.firstIndex(where: { $0.id == n }) { state.steps[i].note = say; changed += 1 }
            else if let a = o["ask"] as? String { state.answer = a; changed += 1 }
            else if let say {  // a whole new list (they meant something else): the crossed-off steps stay, the rest go
                if !fresh {
                    fresh = true
                    let kept = state.steps.filter(\.done), firstOpen = state.steps.first { !$0.done }?.id
                    state.steps = kept
                    state.count = (firstOpen ?? (state.count + 1)) - 1
                    elements = elements.filter { e in kept.contains { $0.id == e.key } }
                }
                addStep(say: say, target: target, kind: kind); changed += 1
            } else if let after = o["after"] as? String, fresh || !after.isEmpty { state.after = after }
        }
        if changed == 0 { state.answer = "The guide had nothing to change for that. Ask it another way." }
        Log.line("guide: question answered, \(changed) change(s)\(fresh ? ", new steps" : "")")
        if state.steps.isEmpty { state.phase = .failed; state.say = state.answer ?? "No steps for that." }
        showRings(); watchForYou(); showBubble()
    }
    // A Type step's web address that's nowhere in what you asked, the goal or the screen: a guess, so never typed (#306: it
    // once made up a /terms page). Returns what the step is about ("the terms of service box"), else nil.
    static func madeUp(_ say: String) -> String? {
        let probe = GuideStep(id: 0, say: say, target: nil, role: "", kind: .type)
        guard let v = probe.value?.lowercased(), v.contains("://") || v.hasPrefix("www.") || v.range(of: #"\.[a-z]{2,}/"#, options: .regularExpression) != nil else { return nil }
        let bare = v.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "www.", with: "")
        let seen = ([lastQuestion, state.goal] + controls.map(\.label)).joined(separator: " ").lowercased()
        if seen.contains(bare) { return nil }
        if let r = say.range(of: #"\s(in|into)\s+(the\s+)?.+$"#, options: .regularExpression) {
            return String(say[r]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^(in|into)\s+"#, with: "", options: .regularExpression)
        }
        return "this box"
    }
    // "Then: …", once: the guide sometimes starts its own text with "Then".
    static func afterLine(_ after: String) -> String {
        let t = after.replacingOccurrences(of: #"^\s*then[:,]?\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return "Then: " + (t.prefix(1).lowercased() + t.dropFirst())
    }
    private static func reword(_ n: Int, say: String, target: Int?, kind: String?) -> Bool {
        guard let i = state.steps.firstIndex(where: { $0.id == n }), !state.steps[i].done else { return false }  // done stays done
        let (k, thenEnter) = GuideStep.kind(say, given: kind)
        state.steps[i].say = say; state.steps[i].kind = k; state.steps[i].thenEnter = thenEnter
        if let c = target.flatMap({ t in controls.first { $0.n == t } }) {
            state.steps[i].target = c.frame; state.steps[i].control = c.n
            if let e = c.element { elements[n] = e }
        }
        return true
    }
    private static func put(after n: Int, say: String, target: Int?, kind: String?) -> Bool {
        guard let i = state.steps.firstIndex(where: { $0.id == n }) ?? (n == 0 ? -1 : nil) else { return false }
        elements = Dictionary(uniqueKeysWithValues: elements.map { ($0.key > n ? $0.key + 1 : $0.key, $0.value) })
        for j in state.steps.indices where state.steps[j].id > n { state.steps[j].id += 1 }
        state.count += 1
        let control = target.flatMap { t in controls.first { $0.n == t } }
        let (k, thenEnter) = GuideStep.kind(say, given: kind)
        if let e = control?.element { elements[n + 1] = e }
        state.steps.insert(GuideStep(id: n + 1, say: say, target: control?.frame, role: control?.role ?? "", control: control?.n, kind: k, thenEnter: thenEnter), at: i + 1)
        return true
    }
    static func openMore() {
        if state.moreOpen { state.moreOpen = false; return showBubble() }  // the bubble again: it folds away
        state.moreOpen = true
        showBubble()
        bubble?.makeKey()  // so the box takes your typing (Penpal stays in the background)
    }

    private static func look(first: Bool, note: String? = nil, changed: Bool = false) {
        follow?.invalidate(); follow = nil
        elements = [:]; clickFocus = nil
        stopWatching()
        clearRings()
        state.steps = []
        state.after = ""
        state.answer = nil; state.answering = false
        state.phase = .looking
        state.say = "Reading the screen"
        state.since = .now
        // Where you dragged it stays (#308, Jason: "not able to move this window"): across looks, and next time too.
        showBubble()
        guard let app = frontApp() else { return fail("There's no app in front to guide.") }
        state.appName = app.localizedName ?? state.appName
        if first, let p = freshPrefetch(app.processIdentifier) {  // read while you typed: straight to Claude
            Log.line("guide: using the screen read ahead \(Int(Date.now.timeIntervalSince(p.at) * 1000))ms ago")
            lookedAt = (p.pid, p.title)
            let quick = instantSteps(state.goal, p.found)
            if let c = quick.first {  // ringed before Claude answers
                state.steps = [GuideStep(id: state.count + 1, say: c.label, target: c.frame, role: c.role, control: c.n)]
                if let e = c.element { elements[state.count + 1] = e }
                state.phase = .showing; state.streaming = true
                Log.line("guide: instant ring on \"\(c.label.prefix(40))\"")
                showRings(); watchForYou(); showBubble()
            }
            return ask(first: first, note: note, changed: changed, window: p.window, found: p.found, png: p.png)
        }
        // The reading is many Accessibility calls, and a slow app can hold one for seconds: off the main
        // thread, so the panel's spinner keeps turning (#250, Jason: a beachball on the first look).
        let pid = app.processIdentifier, ours = ourFrames(), shown = shownArea()
        let t0 = Date.now
        DispatchQueue.global(qos: .userInitiated).async {
            let (window, inApp) = read(pid, under: ours)
            let found = inApp + aroundScreen(after: inApp.count, shown: shown)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                Log.line("guide: read \(found.count) controls in \(Int(Date.now.timeIntervalSince(t0) * 1000))ms")
                guard state.phase == .looking else { return }  // closed meanwhile
                guard let window, window.width > 10 else { return fail("\(AppName.shown) can't see a window in \(state.appName).") }
                lookedAt = (pid, windowTitle(pid))
                ask(first: first, note: note, changed: changed, window: window, found: found)
            } }
        }
    }

    private static func ask(first: Bool, note: String?, changed: Bool = false, window: CGRect, found: [GuideControl], png ready: Data?? = nil) {
        controls = found
        let screen = screenRect(around: window)
        let context = describe(window, screen, found)
        let goal = first && note != nil ? "Goal: \(state.goal). More from me: \(note!)" : "Goal: \(state.goal)"
        let text = first ? goal : note.map { "Not quite. \($0). Goal: \(state.goal). What are the steps on the screen now?" }
            ?? (changed ? "The screen changed. Goal: \(state.goal). What are the steps on the screen now?"
                        : "I did those steps. Goal: \(state.goal). What are the steps on the screen now?")
        Log.line("guide: looking, \(found.count) controls in \(state.appName)")
        // Penpal's own windows aren't in the picture (ScreenCaptureKit leaves them out): the guide once read
        // its own "Looking…" as another app at work (#250). Read ahead, the picture is already here.
        let t0 = Date.now
        @MainActor func send(_ png: Data?) {
            Log.line("guide: picture in \(Int(Date.now.timeIntervalSince(t0) * 1000))ms (\((png?.count ?? 0) / 1024) KB)")
            if state.phase == .looking { state.say = "Thinking"; showBubble() }
            let t1 = Date.now
            asked = t1
            // On the claude started ahead when there is one (#254), and the answer read from the run's own folder.
            WarmAgent.start(.guide, text, png: png, context: context, follow: first ? nil : state.runID) { id in
                Log.line("guide: claude started in \(Int(Date.now.timeIntervalSince(t1) * 1000))ms")
                guard let id else { return fail("\(AppName.shown) couldn't start the guide.") }
                state.runID = id
                streamSteps(id)
                RunState.watch(agent: "guide", id: id) { s in
                    guard state.runID == id, state.phase == .looking || state.streaming else { return }  // closed, or a newer look
                    check(s)
                }
            }
        }
        if let ready { send(ready) } else { snap(screen) { send($0) } }
    }

    // The answer as it's written (events.jsonl, every 40 ms): each whole step line gets its ring at once.
    private static func streamSteps(_ id: String) {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kite/agents/guide/runs/\(id)/events.jsonl")
        var offset: UInt64 = 0, carry = Data(), text = "", used = 0
        streamed = 0
        var replaced = state.steps.isEmpty  // else an instant ring is up: Claude's first step takes its place
        @MainActor func tick() {
            guard state.runID == id, state.phase == .looking || state.streaming else { return }
            if let h = try? FileHandle(forReadingFrom: file) {
                defer { try? h.close() }
                try? h.seek(toOffset: offset)
                var data = carry + ((try? h.readToEnd()) ?? Data())
                offset += UInt64(data.count - carry.count)
                if let nl = data.lastIndex(of: 0x0A) { carry = data[(nl + 1)...]; data = data[...nl] } else { carry = data; data = Data() }
                for line in data.split(separator: 0x0A) {
                    guard let ev = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    if ev["type"] as? String == "result" { return }  // the whole answer: check() takes it from here
                    let d = ((ev["event"] as? [String: Any])?["delta"] as? [String: Any]) ?? [:]
                    if d["type"] as? String == "text_delta", let t = d["text"] as? String { text += t }
                }
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()  // whole lines only
            for l in lines.dropFirst(used) {
                used += 1
                guard let obj = try? JSONSerialization.jsonObject(with: Data(l.trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any],
                      let say = obj["say"] as? String else { continue }
                if !replaced { state.steps = []; replaced = true }  // Claude's steps take the instant ring's place
                if state.steps.isEmpty, let asked { Log.line("guide: first step in \(Int(Date.now.timeIntervalSince(asked) * 1000))ms") }
                addStep(say: say, target: obj["target"] as? Int, kind: obj["do"] as? String)
                streamed += 1
                state.phase = .showing; state.streaming = true
                showRings(); watchForYou(); showBubble()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { MainActor.assumeIsolated { tick() } }
        }
        tick()
    }

    private static var streamed = 0  // Claude's steps that came while it wrote (this look)

    private static func addStep(say: String, target: Int?, kind: String?) {
        // After a step that switches app (a Dock icon), the rest is in an app not on screen yet: no ring could find it
        // (#308, Jason: "didnt highlight or check off the address bar"). The next look, in that app, gives those steps.
        if let last = state.steps.last, !last.done, last.role == "dockitem" { return Log.line("guide: steps after an app switch wait for the next look") }
        let control = target.flatMap { n in controls.first { $0.n == n } }
        let (k, thenEnter) = GuideStep.kind(say, given: kind)
        // "Click the address bar" then "Type: …" on the same box is one step (#308): the typing step takes its place.
        if k == .type, let last = state.steps.last, !last.done, last.kind == .click, last.control == control?.n,
           ["address bar", "search box", "search field", "url bar", "the box"].contains(where: { last.say.lowercased().contains($0) })
            || (GuideStep(id: 0, say: say, target: nil, role: "", kind: .type).value.map { last.say.lowercased().contains($0.lowercased()) } ?? false) {
            state.steps.removeLast(); elements[last.id] = nil; state.count -= 1
            Log.line("guide: a click on the box merged into the typing on it")
        }
        state.count += 1
        if let e = control?.element { elements[state.count] = e }
        state.steps.append(GuideStep(id: state.count, say: say, target: control?.frame, role: control?.role ?? "", control: control?.n, kind: k, thenEnter: thenEnter))
    }

    private static var asked: Date?

    // This app's own windows (the steps panel, the rings, the dock), in Accessibility coordinates: what's
    // under them is still on screen (#250, Nike's search icon sat under the panel and lost its ring).
    private static func ourFrames() -> [CGRect] {
        NSApp.windows.filter(\.isVisible).map { w in
            let h = NSScreen.screens.first?.frame.maxY ?? 0
            return CGRect(x: w.frame.minX, y: h - w.frame.maxY, width: w.frame.width, height: w.frame.height)
        }
    }
    private static func shownArea() -> CGRect {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.reduce(CGRect.null) { r, s in r.union(CGRect(x: s.frame.minX, y: h - s.frame.maxY, width: s.frame.width, height: s.frame.height)) }
    }

    private static func describe(_ window: CGRect, _ screen: CGRect, _ found: [GuideControl]) -> String {
        let list = found.map { c in
            "\(c.n). \(c.role) \"\(c.label)\" at \(Int(c.frame.minX)),\(Int(c.frame.minY)) size \(Int(c.frame.width))x\(Int(c.frame.height))"
        }.joined(separator: "\n")
        return "The picture is the whole screen, at \(Int(screen.minX)),\(Int(screen.minY)) size \(Int(screen.width))x\(Int(screen.height)).\n"
            + "App in front: \(state.appName). Its window at \(Int(window.minX)),\(Int(window.minY)) size \(Int(window.width))x\(Int(window.height)).\n"
            + "Controls (number, role, label, position in points from the top-left of the main screen): the app's window and menu bar, "
            + "then the Dock's icons (dockitem) and the menu bar's icons (menuextra, with the app they belong to):\n" + list
    }

    // The screen the window is on, in Accessibility coordinates (top-left of the main screen).
    static func screenRect(around window: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        let mid = NSPoint(x: window.midX, y: h - window.midY)
        let s = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = s?.frame else { return window }
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }

    // Around the app (#250, Jason: "show me all the apps jason created on this screen" meant the Dock):
    // the Dock's icons and the menu bar's icons, so "on this screen" is the whole screen.
    nonisolated static func aroundScreen(after n: Int, shown: CGRect) -> [GuideControl] {
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
        func frame(_ e: AXUIElement) -> CGRect? {
            guard let p = attr(e, "AXPosition"), let s = attr(e, "AXSize") else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
            return CGRect(origin: point, size: size)
        }
        // shown: every screen; a hidden Dock sits off them
        var out: [GuideControl] = []
        func add(_ e: AXUIElement, role: String, label: String?) {
            guard out.count < 80, let f = frame(e), f.width > 2, f.height > 2, shown.contains(CGPoint(x: f.midX, y: f.midY)),
                  let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            out.append(GuideControl(n: n + out.count + 1, role: role, label: String(label.prefix(60)), frame: f, element: e))
        }
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            for list in attr(AXUIElementCreateApplication(dock.processIdentifier), "AXChildren") as? [AXUIElement] ?? [] {
                for item in attr(list, "AXChildren") as? [AXUIElement] ?? [] {
                    add(item, role: "dockitem", label: (attr(item, "AXTitle") as? String) ?? (attr(item, "AXDescription") as? String))
                }
            }
        }
        // Every app at once: one by one took 2.9 s (#250, the first look's beachball), most of it apps
        // that have no menu bar icon taking their time to say so.
        let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { ($0.processIdentifier, $0.localizedName ?? "") }
        let lock = NSLock()
        var bars: [Int: [(AXUIElement, String)]] = [:]
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let a = AXUIElementCreateApplication(apps[i].0)
            AXUIElementSetMessagingTimeout(a, 0.25)  // an app that's busy doesn't hold up the look
            guard let bar = attr(a, "AXExtrasMenuBar") else { return }
            let items = (attr(bar as! AXUIElement, "AXChildren") as? [AXUIElement] ?? []).map { item in
                let name = (attr(item, "AXDescription") as? String) ?? (attr(item, "AXTitle") as? String) ?? ""
                return (item, [name, apps[i].1].filter { !$0.isEmpty }.joined(separator: " · "))
            }
            lock.lock(); bars[i] = items; lock.unlock()
        }
        for i in bars.keys.sorted() { for (item, label) in bars[i]! { add(item, role: "menuextra", label: label) } }
        return out
    }

    // Guide me's model (#307): Settings › Magic, by full id as Enhance's are. Bench: bench/agent-speed/guide-models.py.
    // Bench (results-2026-10-07-guide-models.json, 3 real screens, warm): Opus 5.5, Sonnet 5.5 and Haiku 5.5 rang the right
    // controls on all 3; Haiku 4.5 rang "Men" instead of the search box on a shopping page. First token, median: Haiku 4.5
    // 0.8 s, Haiku 5.5 1.3 s, Opus 5.5 1.7 s, Sonnet 5.5 1.9 s. Haiku 5.5 is the default: right on all 3 and quick. Haiku 4.5
    // is offered for an older Claude Code, said honestly (Jason: "lets also order this as Opus, Sonnet, and Haiku, and add
    // haiku 4.5 as well"), with thinking off as in Enhance. Until #307 Guide me ran Claude Code's "sonnet", Claude Sonnet 5.
    static let models: [(id: String, name: String, note: String)] = [
        ("opus", "Opus 5.5", "First ring in about 2 seconds. Thorough; sometimes an extra step"),
        ("sonnet", "Sonnet 5.5", "First ring in about 2 seconds. Careful steps"),
        ("haiku-5-5", "Haiku 5.5", "First ring in about 1.5 seconds. Quick and right. The default"),
        ("haiku", "Haiku 4.5", "First ring in under a second. For older Claude Code; sometimes rings the wrong thing"),
    ]
    static let modelKey = "guide.model"
    static let defaultModel = "haiku-5-5"
    static var pickedModel: String {
        let m = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        return models.contains { $0.id == m } ? m : defaultModel
    }
    static func pick(_ m: String) {
        UserDefaults.standard.set(m, forKey: modelKey)
        Enhance.missing.removeAll()  // a new pick: try it
        Log.line("guide: model \(m)")
        WarmAgent.guide.prepare()
    }
    static var picked: Enhance.Choice {
        let arg = Enhance.args[pickedModel] ?? pickedModel
        // Haiku 5.5's fallback here is Claude Code's Sonnet, not Haiku 4.5: Haiku 4.5 missed rings in the bench.
        return Enhance.Choice(name: models.first { $0.id == pickedModel }?.name ?? pickedModel, arg: arg,
                              key: arg == "claude-haiku-5-5" ? "claude-sonnet-5-5" : arg)
    }
    // What goes to kite: the pick, or its fallback once this Claude Code has said it can't run the pick.
    static var pickedModelArg: String {
        let p = picked
        if Enhance.missing.contains(p.arg), let b = p.fallback { return b.arg }
        return p.arg
    }
    private static var fellBack: String?  // the note once the fallback has answered

    private static func check(_ run: RunState) {
        if let asked { Log.line("guide: answer in \(Int(Date.now.timeIntervalSince(asked) * 1000))ms") }
        // A model this Claude Code can't run (#307, as Enhance, #302): the closest one it has, said in the panel.
        if run.errorKind == "model_not_found" {
            let p = picked, used = pickedModelArg
            Enhance.missing.insert(used)
            if used == p.arg, let b = p.fallback, !Enhance.missing.contains(b.arg) {
                Log.line("guide: \(p.name) not in this Claude Code; \(b.name) instead")
                fellBack = "\(b.name) answered. Your Claude Code doesn't have \(p.name) yet. Update Claude Code, or pick another model in Settings › Magic."
                state.streaming = false
                return look(first: true)
            }
            state.streaming = false
            return fail(used == p.arg ? "Your Claude Code doesn't have \(p.name) yet. Update Claude Code, or pick another model in Settings › Magic."
                                      : "Your Claude Code can't run \(p.name) or \(p.fallback?.name ?? "the closest model"). Update Claude Code, then try again.")
        }
        WarmAgent.guide.prepare(resume: run.session)  // the next look follows this session: have its claude ready
        state.streaming = false
        guard run.status == "done", let text = run.result, let answer = parse(text) else {
            if streamed > 0 { return showBubble() }  // the steps came; only the last line is missing
            return fail(run.plainProblem ?? "The guide didn't answer. Try Look again.")
        }
        // Steps that came while it wrote stay (crossed off ones too); the rest of the answer fills in. Without
        // any (an older answer in one piece), its steps replace an instant ring.
        if streamed == 0 { state.steps = [] }
        for s in answer.steps.dropFirst(streamed) { addStep(say: s.say, target: s.target, kind: s.kind) }
        state.after = answer.after
        state.last = answer.done
        if let n = fellBack { state.answer = n; fellBack = nil }
        if !state.steps.isEmpty, state.steps.allSatisfy(\.done) {  // all crossed off while it was still writing
            showRings(); showBubble()
            if state.last { state.say = state.after.isEmpty ? "All done." : state.after; state.phase = .done; clearRings(); return showBubble() }
            return DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if state.steps.allSatisfy(\.done) { next() } }
        }
        if state.steps.isEmpty {  // "done" with steps (e.g. "circle all the sessions") still shows them
            state.say = answer.after.isEmpty ? (answer.done ? "Done." : "No steps found on this screen.") : answer.after
            state.phase = answer.done ? .done : .failed
        } else {
            state.phase = .showing
        }
        Log.line("guide: \(state.steps.count) step(s), \(state.steps.filter { $0.target != nil }.count) on screen\(answer.done ? ", done" : "")")
        showRings()
        watchForYou()
        startFollowing()
        showBubble()
    }

    private static func fail(_ why: String) {
        state.say = why
        state.phase = .failed
        showBubble()
    }

    // Crosses a step off once you've done it: a click inside its ring, or for a text box, Return after
    // typing (the first one not done yet). A step that isn't on screen you cross off in the list.
    // Kite only watches; your click goes to the app as usual.
    private static var youMonitor: Any?
    private static func watchForYou() {
        if dryRun { return }
        stopWatching()
        guard state.phase == .showing else { return }
        youMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            let h = NSScreen.screens.first?.frame.maxY ?? 0
            let at = NSEvent.mouseLocation
            let returnKey = event.type == .keyDown && (event.keyCode == 36 || event.keyCode == 76)
            // A real character: not a shortcut, not Tab, Esc, arrows or other function keys.
            let typed = event.type == .keyDown && !returnKey && event.modifierFlags.isDisjoint(with: [.command, .control])
                && (event.characters ?? "").unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }
            MainActor.assumeIsolated {
                let f = event.type == .keyDown ? focusNow() : nil
                let afterClick = f?.element.map { e in clickFocus.map { CFEqual($0, e) } ?? false } ?? false
                let act: GuideAct? = event.type == .leftMouseDown ? .click(CGPoint(x: at.x, y: h - at.y))
                    : returnKey ? .returnKey(focus: f?.frame, text: f?.text ?? false, afterClick: afterClick)
                    : typed ? .typed(focus: f?.frame, text: f?.text ?? false, afterClick: afterClick) : nil
                if let act, let id = crossing(state.steps, act) {
                    cross(id)
                    // The box a click step opened: typing there counts for the next steps, wherever it grew to.
                    if case .click = act { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { clickFocus = focusNow()?.element } }
                }
            }
        }
    }

    // Which step what you did crosses off, if any. A step waits for the ones before it on the same control
    // (click the box, then type, then Enter, in order); steps on different controls go in any order.
    static func sameControl(_ a: GuideStep, _ b: GuideStep) -> Bool {
        (a.control != nil && a.control == b.control) || (a.target != nil && a.target == b.target)
    }
    static func crossing(_ steps: [GuideStep], _ act: GuideAct) -> Int? {
        let same = sameControl
        func ready(_ s: GuideStep) -> Bool {
            !s.done && !steps.contains { $0.id < s.id && !$0.done && same($0, s) }
        }
        // Typing and Return count for a step whose box has focus (or anywhere, when focus can't be read):
        // its box, or a text box near it, or the one that took focus right after the click step.
        func focused(_ s: GuideStep, _ focus: CGRect?, _ text: Bool, _ afterClick: Bool) -> Bool {
            guard let focus, let t = s.target else { return true }
            return t.insetBy(dx: -6, dy: -6).intersects(focus) || (text && (afterClick || t.insetBy(dx: -120, dy: -120).intersects(focus)))
        }
        switch act {
        case .click(let p):
            return steps.first { ready($0) && $0.kind == .click && ($0.target.map { $0.insetBy(dx: -10, dy: -10).contains(p) } ?? false) }?.id
        case .typed(let focus, let text, let afterClick):
            return steps.first { ready($0) && $0.kind == .type && !$0.thenEnter && focused($0, focus, text, afterClick) }?.id
        case .returnKey(let focus, let text, let afterClick):
            // Return in a text box also counts once the typing before it (same control) is done.
            return steps.first { s in ready(s) && (s.kind == .enter || (s.kind == .type && s.thenEnter))
                && (focused(s, focus, text, afterClick) || (text && steps.contains { $0.id < s.id && $0.done && $0.kind == .type && same($0, s) })) }?.id
        }
    }

    private static var clickFocus: AXUIElement?
    static var elements: [Int: AXUIElement] = [:]  // step number → its control, to follow it

    // What has keyboard focus now, in any app: where it is, whether it's a text box, and the element.
    private static func focusNow() -> (frame: CGRect?, text: Bool, element: AXUIElement?)? {
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
        guard let f = attr(AXUIElementCreateSystemWide(), "AXFocusedUIElement") else { return nil }
        let e = f as! AXUIElement
        let role = attr(e, "AXRole") as? String ?? ""
        return (focusFrame(), ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role), e)
    }

    // Rings follow their controls: every half second while steps show, each one's control is found again
    // and its ring moves if it moved or grew. When the page changes (the window's title), it looks again,
    // as the panel promises (#250: Nike's search box grew when clicked, and the results page never got a look).
    private static var follow: Timer?
    private static var lookedAt: (pid: pid_t, title: String?)?
    private static func windowTitle(_ pid: pid_t) -> String? {
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let w = attr(app, "AXFocusedWindow") else { return nil }
        return attr(w as! AXUIElement, "AXTitle") as? String
    }
    private static func startFollowing() {
        if dryRun { return }
        follow?.invalidate()
        follow = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { followTick() } }
    }
    private static func followTick() {
        guard state.phase == .showing else { return }
        if let at = lookedAt, let now = windowTitle(at.pid), let was = at.title, now != was {
            Log.line("guide: the page changed, looking again")
            lookedAt = nil
            return look(first: state.runID == nil, changed: true)
        }
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
        var moved = false
        for i in state.steps.indices where !state.steps[i].done {
            guard let e = elements[state.steps[i].id], let p = attr(e, "AXPosition"), let z = attr(e, "AXSize") else { continue }
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(z as! AXValue, .cgSize, &size)
            let now = CGRect(origin: point, size: size)
            guard size.width > 2, let was = state.steps[i].target, abs(now.minX - was.minX) + abs(now.minY - was.minY) + abs(now.width - was.width) + abs(now.height - was.height) > 3 else { continue }
            state.steps[i].target = now
            moved = true
        }
        if moved { Log.line("guide: a control moved, rings follow"); showRings(); showBubble() }
        crossByOutcome(url: currentURL(), boxText: { id in elements[id].flatMap { attr($0, "AXValue") as? String } })
    }

    // Done when you can see it's done (#308, Jason: step 2 "wasn't crossed off" though the page was there): the browser
    // now shows the address a step goes to, or the box a Type step names now holds its text. The click needn't be seen.
    static func crossByOutcome(url: String?, boxText: (Int) -> String?) {
        func bare(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "www.", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ .,"))
        }
        let here = url.map(bare)
        var hit: [Int] = []
        for st in state.steps where !st.done && st.kind != .see {
            let addr = st.say.lowercased().range(of: #"[a-z0-9-]+(\.[a-z0-9-]+)+(/[^\s,"]*)?"#, options: .regularExpression).map { bare(String(st.say.lowercased()[$0])) }
            if let addr, addr.contains("."), let here, here.hasPrefix(addr) || here.contains(addr) { hit.append(st.id); continue }
            if st.kind == .type, !st.thenEnter, let v = st.value, let text = boxText(st.id), text.lowercased().contains(v.lowercased()) { hit.append(st.id) }
        }
        guard !hit.isEmpty else { return }
        // A visit reached: the steps before it that led there are done too (clicking the address bar, typing it).
        if let lastHit = hit.max() { for st in state.steps where !st.done && st.id < lastHit && st.kind != .see && !hit.contains(st.id) { hit.append(st.id) } }
        Log.line("guide: crossed off by what's on screen: \(hit.sorted())")
        for id in hit.sorted() { cross(id) }
    }
    // The front browser's address: the window's document (Safari), else its address field (Chrome's omnibox and the like).
    static func currentURL() -> String? {
        guard let pid = (lookedAt?.pid) ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
        guard let w = attr(app, "AXFocusedWindow") else { return nil }
        let win = w as! AXUIElement
        if let doc = attr(win, "AXDocument") as? String, doc.hasPrefix("http") { return doc }
        func find(_ e: AXUIElement, _ depth: Int) -> String? {
            if depth > 7 { return nil }
            if (attr(e, "AXRole") as? String) == "AXTextField" {
                let name = [attr(e, "AXDescription"), attr(e, "AXTitle"), attr(e, "AXIdentifier")].compactMap { $0 as? String }.joined(separator: " ").lowercased()
                if ["address", "smart search", "omnibox", "location"].contains(where: name.contains), let v = attr(e, "AXValue") as? String, !v.isEmpty { return v }
            }
            for c in (attr(e, "AXChildren") as? [AXUIElement] ?? []) { if let v = find(c, depth + 1) { return v } }
            return nil
        }
        return find(win, 0)
    }

    // The frame of whatever has keyboard focus now, in any app.
    private static func focusFrame() -> CGRect? {
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
        guard let f = attr(AXUIElementCreateSystemWide(), "AXFocusedUIElement"),
              let p = attr(f as! AXUIElement, "AXPosition"), let s = attr(f as! AXUIElement, "AXSize") else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    // A step done (or undone, from the list). When they all are, look again for the next screen's steps,
    // after a moment for the app to show what the last click opened.
    static func cross(_ id: Int) {
        guard state.phase == .showing, let i = state.steps.firstIndex(where: { $0.id == id }) else { return }
        state.steps[i].done.toggle()
        Log.line("guide: step \(id) \(state.steps[i].done ? "done" : "not done")")
        showRings()
        showBubble()
        if state.steps.allSatisfy(\.done), !state.streaming {  // still writing: the rest of its steps may come
            stopWatching()
            if state.last {  // the goal is reached with these: nothing to look for
                state.say = state.after.isEmpty ? "All done." : state.after
                state.phase = .done
                clearRings()
                return showBubble()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { if state.steps.allSatisfy(\.done) { next() } }
        }
    }

    // Copy (#264): the step's text on the clipboard, left there; "Copied" for a moment.
    static func copy(_ id: Int) {
        guard let v = state.steps.first(where: { $0.id == id })?.value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v, forType: .string)
        state.copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if state.copied == id { state.copied = nil } }
    }

    private static func stopWatching() {
        if let m = youMonitor { NSEvent.removeMonitor(m) }
        youMonitor = nil
    }

    static func close() {
        WarmAgent.guide.stop()
        stopWatching()
        follow?.invalidate(); follow = nil
        watch?.invalidate()
        [askPanel, bubble].forEach { $0?.orderOut(nil) }
        askPanel = nil; bubble = nil
        clearRings()
    }

    // ---------- Reading the app ----------

    static var target: NSRunningApplication?  // --time-guide: this app, not the one in front
    private static func frontApp() -> NSRunningApplication? {
        if let target { return target }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { return front }
        return lastApp?.isTerminated == false ? lastApp : nil
    }

    nonisolated static let roles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                     "AXMenuBarItem", "AXTextField", "AXSearchField", "AXLink", "AXRow", "AXCell",
                                     "AXSlider", "AXDisclosureTriangle", "AXComboBox", "AXTab", "AXIncrementor", "AXTextArea"]
    nonisolated static let inputs: Set<String> = ["textfield", "searchfield", "textarea", "combobox"]

    // The focused window's controls, plus the menu bar, numbered. Capped so a huge window can't stall it.
    nonisolated static func read(_ pid: pid_t, under ours: [CGRect] = [], windowOnly: Bool = false) -> (CGRect?, [GuideControl]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(e, n as CFString, &v)
            return v
        }
        func frame(_ e: AXUIElement) -> CGRect? {
            guard let p = attr(e, "AXPosition"), let s = attr(e, "AXSize") else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &point)
            AXValueGetValue(s as! AXValue, .cgSize, &size)
            return CGRect(origin: point, size: size)
        }
        func text(_ e: AXUIElement) -> String? {
            for key in ["AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue", "AXHelp"] {  // search boxes often only have a placeholder
                if let s = attr(e, key) as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            }
            return nil
        }
        // Rows and cells carry their words in child text.
        func childText(_ e: AXUIElement, depth: Int = 0) -> String? {
            guard depth < 3 else { return nil }
            for c in attr(e, "AXChildren") as? [AXUIElement] ?? [] {
                if attr(c, "AXRole") as? String == "AXStaticText", let s = text(c) { return s }
                if let s = childText(c, depth: depth + 1) { return s }
            }
            return nil
        }
        var out: [GuideControl] = []
        // Really on screen: what the app shows at its middle is it (or inside it). A row scrolled up under
        // a header still has a frame, and the guide ringed one there (#250, Claude's session list).
        var area = CGFloat.infinity  // the window's, set once it's found
        func visible(_ e: AXUIElement, _ f: CGRect) -> Bool {
            // Test a point of it that isn't under one of this app's windows; all of it under them counts as shown.
            let points = [CGPoint(x: f.midX, y: f.midY)] + [(0.2, 0.5), (0.8, 0.5), (0.5, 0.2), (0.5, 0.8), (0.1, 0.1), (0.9, 0.9), (0.9, 0.1), (0.1, 0.9)]
                .map { CGPoint(x: f.minX + f.width * $0.0, y: f.minY + f.height * $0.1) }
            guard let at = points.first(where: { p in !ours.contains { $0.contains(p) } }) else { return true }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(at.x), Float(at.y), &hit) == .success, var h = hit else { return true }
            let top = h
            for _ in 0..<10 {
                if CFEqual(h, e) { return true }
                guard let up = attr(h, "AXParent") else { break }
                h = up as! AXUIElement
            }
            // Or what's on top is its own close wrapper (a toolbar item's group around the button): one of its
            // few nearest parents, and a small part of the window (not the window or a whole pane).
            var p: AXUIElement = e
            var near: [AXUIElement] = []  // its parent and grandparent
            for i in 0..<4 {
                guard let up = attr(p, "AXParent") else { break }
                p = up as! AXUIElement
                if i < 2 { near.append(p) }
                if CFEqual(p, top) { return (frame(p).map { $0.width * $0.height } ?? .infinity) <= area / 12 }
            }
            // Or what's on top is drawn inside it by a neighbour: Safari's address field shows its URL as text
            // laid over the field, a sibling, so the field looked covered and never made the list (#250).
            guard let tf = frame(top), f.insetBy(dx: -4, dy: -4).contains(tf) else { return false }
            var t = top
            for _ in 0..<3 {
                guard let up = attr(t, "AXParent") else { return false }
                t = up as! AXUIElement
                if near.contains(where: { CFEqual($0, t) }) { return true }
            }
            return false
        }
        func add(_ e: AXUIElement, _ role: String) {
            guard out.count < 400, let f = frame(e), f.width > 2, f.height > 2 else { return }
            guard role == "AXMenuBarItem" || visible(e, f) else { return }
            guard let label = text(e) ?? childText(e) else { return }
            let r = role.replacingOccurrences(of: "AX", with: "").lowercased()
            out.append(GuideControl(n: out.count + 1, role: r, label: String(label.prefix(60)), frame: f, element: e))
        }
        if let bar = attr(app, "AXMenuBar") {
            for item in (attr(bar as! AXUIElement, "AXChildren") as? [AXUIElement] ?? []).dropFirst() { add(item, "AXMenuBarItem") }
        }
        guard let win = attr(app, "AXFocusedWindow") ?? (attr(app, "AXWindows") as? [AXUIElement])?.first else { return (nil, out) }
        let window = win as! AXUIElement
        if windowOnly { return (frame(window), []) }  // just where the window is (has the screen moved?)
        area = frame(window).map { $0.width * $0.height } ?? .infinity
        var queue = [window], seen = 0
        while !queue.isEmpty, seen < 6000, out.count < 400 {
            let e = queue.removeFirst()
            seen += 1
            let role = attr(e, "AXRole") as? String ?? ""
            if roles.contains(role) { add(e, role) }
            var kids = attr(e, "AXChildren") as? [AXUIElement] ?? []
            // A long list's first rows are enough: its cells used to fill the whole list, and the toolbar
            // (search box, tabs) never made it in (#250, found on Activity Monitor).
            if role == "AXTable" || role == "AXOutline" {
                var rows = 0
                kids = kids.filter { k in
                    guard attr(k, "AXRole") as? String == "AXRow" else { return true }
                    rows += 1
                    return rows <= 12
                }
            }
            queue += kids
        }
        // At most 200, but every text box stays: typing is often the step (e.g. Claude's message box).
        var keep = 200 - out.filter { inputs.contains($0.role) }.count
        let trimmed = out.filter { c in
            if inputs.contains(c.role) { return true }
            keep -= 1
            return keep >= 0
        }
        return (frame(window), trimmed.enumerated().map { GuideControl(n: $0.offset + 1, role: $0.element.role, label: $0.element.label, frame: $0.element.frame, element: $0.element.element) })
    }

    private static func capture(_ rect: CGRect, done: @escaping @MainActor (Data?) -> Void) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kite-guide-\(UUID().uuidString).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", file.path]
        task.terminationHandler = { _ in
            Task { @MainActor in
                let png = try? Data(contentsOf: file)
                try? FileManager.default.removeItem(at: file)
                done(png)
            }
        }
        do { try task.run() } catch { done(nil) }
    }

    // {"steps": [{"say", "target"}], "after", "done"}; an older one-step answer {"say", "target", "done"} too.
    static func parse(_ text: String) -> (steps: [(say: String, target: Int?, kind: String?)], after: String, done: Bool)? {
        // JSON lines (#259): one step per line, then {"after", "done"}.
        let objs = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any] }
        if objs.count > 1 || objs.first?["say"] != nil || (objs.first?["after"] != nil && objs.first?["steps"] == nil) {
            let steps = objs.compactMap { o in (o["say"] as? String).map { (say: $0, target: o["target"] as? Int, kind: o["do"] as? String) } }
            let end = objs.last { $0["say"] == nil }
            return (Array(steps.prefix(9)), end?["after"] as? String ?? "", end?["done"] as? Bool ?? false)
        }
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any] else { return nil }
        let done = obj["done"] as? Bool ?? false
        if let list = obj["steps"] as? [[String: Any]] {
            let steps = list.compactMap { s in (s["say"] as? String).map { (say: $0, target: s["target"] as? Int, kind: s["do"] as? String) } }
            return (Array(steps.prefix(9)), obj["after"] as? String ?? "", done)
        }
        guard let say = obj["say"] as? String else { return nil }
        return done ? ([], say, true) : ([(say, obj["target"] as? Int, nil)], "", false)
    }

    // --guide-sim <out folder>: what crosses off what, for set sequences (Jason's Google search among
    // them), through the same crossing() the live watcher uses; prints PASS or FAIL per action and draws
    // the steps panel after each action of the first one.
    static func simulate(out: String) -> Bool {
        let box = CGRect(x: 400, y: 200, width: 500, height: 40), other = CGRect(x: 100, y: 600, width: 80, height: 30)
        let inBox = CGPoint(x: box.midX, y: box.midY), elsewhere = CGRect(x: 0, y: 0, width: 10, height: 10)
        let nikeSmall = CGRect(x: 1198, y: 171, width: 124, height: 36), nikeBig = CGRect(x: 600, y: 160, width: 700, height: 60).offsetBy(dx: -400, dy: 300)
        func step(_ id: Int, _ say: String, _ t: CGRect?, _ given: String? = nil) -> GuideStep {
            let (k, e) = GuideStep.kind(say, given: given)
            return GuideStep(id: id, say: say, target: t, role: "textfield", kind: k, thenEnter: e)
        }
        typealias Case = (name: String, steps: [GuideStep], acts: [(String, GuideAct, Int?)])
        let cases: [Case] = [
            ("Google, three steps on one box (the PM's)", [step(1, "Click the search bar", box), step(2, "Type: onion ring recipe", box), step(3, "Press Enter to search", box)],
             [("click the box", .click(inBox), 1), ("click it again", .click(inBox), nil), ("type o", .typed(focus: box), 2),
              ("type n", .typed(focus: box), nil), ("Return", .returnKey(focus: box), 3)]),
            ("Google as Jason got it (type, Enter)", [step(1, "Type: onion ring recipe", box), step(2, "Press Enter to search", box)],
             [("click the box", .click(inBox), nil), ("Return before typing", .returnKey(focus: box), nil), ("type o", .typed(focus: box), 1), ("Return", .returnKey(focus: box), 2)]),
            ("typing somewhere else", [step(1, "Type: onion ring recipe", box)],
             [("type in another box", .typed(focus: elsewhere), nil), ("type in the box", .typed(focus: box), 1)]),
            ("type, then Enter, as one step", [step(1, "Type: nearest Chipotle to me, then press Enter", box)],
             [("type n", .typed(focus: box), nil), ("Return", .returnKey(focus: box), 1)]),
            ("the guide's own kinds", [step(1, "Search box", box, "click"), step(2, "Enter your email", box, "type")],
             [("type x", .typed(focus: box), nil), ("click the box", .click(inBox), 1), ("type x", .typed(focus: box), 2)]),
            ("Nike: the box grows when clicked (the field moved away)",
             [step(4, "Click the Search Products box", nikeSmall), step(5, "Type: Air Force 1", nikeSmall), step(6, "Press Return to search", nikeSmall)],
             [("click the small box", .click(CGPoint(x: nikeSmall.midX, y: nikeSmall.midY)), 4),
              ("type in the grown box, far off", .typed(focus: nikeBig, text: true, afterClick: true), 5),
              ("Return in the grown box", .returnKey(focus: nikeBig, text: true, afterClick: true), 6)]),
            ("Nike: typing in some other far box doesn't count",
             [step(4, "Click the Search Products box", nikeSmall), step(5, "Type: Air Force 1", nikeSmall)],
             [("click the small box", .click(CGPoint(x: nikeSmall.midX, y: nikeSmall.midY)), 4),
              ("type in a far box that didn't take focus from the click", .typed(focus: elsewhere, text: true, afterClick: false), nil),
              ("type in a box just beside it", .typed(focus: nikeSmall.offsetBy(dx: 90, dy: 0), text: true), 5)]),
            ("two controls, any order", [step(1, "Click Save", box), step(2, "Click Cancel", other)],
             [("click Cancel", .click(CGPoint(x: other.midX, y: other.midY)), 2), ("click Save", .click(inBox), 1)]),
        ]
        var ok = true, first = true
        _ = NSApplication.shared
        for c in cases {
            print("== \(c.name): " + c.steps.map { "\($0.id) \($0.kind.rawValue)\($0.thenEnter ? "+enter" : "")" }.joined(separator: ", "))
            var steps = c.steps
            if first { state = GuideState(); state.goal = "search onion ring recipe on Google"; state.phase = .showing; state.steps = steps }
            for (n, (what, act, want)) in c.acts.enumerated() {
                let got = crossing(steps, act)
                if let got, let i = steps.firstIndex(where: { $0.id == got }) { steps[i].done = true }
                let pass = got == want
                ok = ok && pass
                print("  \(pass ? "PASS" : "FAIL") \(what) → \(got.map { "step \($0)" } ?? "nothing")\(pass ? "" : " (wanted \(want.map { "step \($0)" } ?? "nothing"))")")
                if first {
                    state.steps = steps
                    let host = NSHostingView(rootView: GuideBubble(state: state).environment(\.colorScheme, .dark))
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    win.contentView = host
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bmp)
                        try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("sim-\(n + 1).png"))
                    }
                }
            }
            first = false
        }
        // Where the panel goes: away from rings, top right when it can.
        let v = NSRect(x: 0, y: 80, width: 1470, height: 820), size = NSSize(width: 340, height: 450)
        let topRight = NSRect(x: 1360, y: 820, width: 60, height: 40), bottomRight = NSRect(x: 1360, y: 120, width: 60, height: 40)
        for (what, rings, want) in [("no rings", [NSRect](), "top right"), ("a ring under the top right (Nike's search icon)", [topRight], "bottom right"),
                                    ("rings top right and bottom right", [topRight, bottomRight], "bottom left")] {
            let o = spot(for: size, screen: v, rings: rings)
            let top = o.y + size.height > v.maxY - 40, bottom = o.y < v.minY + 40
            let got = (top ? "top" : bottom ? "bottom" : "middle") + (o.x > v.midX ? " right" : " left")
            let pass = got == want
            ok = ok && pass
            print("  \(pass ? "PASS" : "FAIL") panel with \(what) → \(got)\(pass ? "" : " (wanted \(want))")")
        }

        func draw(_ name: String) {
            let host = NSHostingView(rootView: GuideBubble(state: state).environment(\.colorScheme, .dark))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bmp)
                try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("sim-\(name).png"))
            }
        }
        // Copy (#264): the text each Type step copies (Jason's Amazon run among them).
        print("== Copy")
        for (say, want) in [("Type: amazon.com/mc/youraccount/managePrime", "amazon.com/mc/youraccount/managePrime"),
                            ("Type: nearest Chipotle to me, then press Enter", "nearest Chipotle to me"),
                            ("Type: \"onion ring recipe\"", "onion ring recipe"), ("Type: air force 1 in the search box", "air force 1"),
                            ("Type your email", nil), ("Click the address bar", nil)] as [(String, String?)] {
            let got = step(1, say, box).value
            ok = ok && got == want
            print("  \(got == want ? "PASS" : "FAIL") \"\(say)\" copies \(got.map { "\"\($0)\"" } ?? "nothing")\(got == want ? "" : " (wanted \(want ?? "nothing"))")")
        }
        state.phase = .showing; state.goal = "help me cancel my amazon subscription"; state.after = "Opens your Prime membership page"
        state.steps = [step(6, "Click the address bar", box), step(7, "Type: amazon.com/mc/youraccount/managePrime", box), step(8, "Press Return", box)]
        draw("type")
        state.copyHover = 7
        draw("copy-hover")
        state.copyHover = nil
        state.copied = 7
        draw("copied")
        state.copied = nil
        state.steps = [step(1, "Type: nike.com, then press Enter", nil)]
        draw("type-noring")
        state.after = ""
        // A step with nothing to ring says so in the list.
        state.steps = [step(1, "Click the address bar", nil), step(2, "Type: nike.com, then press Enter", nil)]
        draw("noring")
        // Made small: the pill, with how many are left.
        state.steps = [step(3, "Type: air force 1 in the search box", box), step(4, "Press Return to search", box)]
        state.minimized = true
        draw("pill")
        // Thinking, two seconds in.
        state.minimized = false
        state.phase = .looking; state.say = "Thinking"; state.since = Date.now.addingTimeInterval(-2.2)
        draw("thinking")
        state.minimized = true
        draw("pill-thinking")
        print(ok ? "all passed" : "SOME FAILED")
        return ok
    }

    // --guide-check <bundle id> <goal> <out.png>: a real look at that app's window and the guide's real
    // answer, drawn as you'd see it (the window with its numbered rings in out.png, the steps in
    // out-steps.png), with nothing put on screen and nothing clicked. For checking by rendering.
    static func check(bundle: String, goal: String, out: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first, let root = Kite.root else { return print("not running: \(bundle)") }
        state = GuideState()
        state.goal = goal
        state.appName = app.localizedName ?? bundle
        var t = Date.now
        _ = AgentStore.shared
        print("timing: agent store first use \(Int(Date.now.timeIntervalSince(t) * 1000))ms")
        t = Date.now; AgentStore.shared.refresh()
        print("timing: agent store refresh \(Int(Date.now.timeIntervalSince(t) * 1000))ms")
        t = Date.now
        let (w, inApp) = read(app.processIdentifier)
        print("timing: read \(inApp.count) controls \(Int(Date.now.timeIntervalSince(t) * 1000))ms")
        t = Date.now
        _ = aroundScreen(after: 0, shown: shownArea())
        print("timing: Dock and menu bar \(Int(Date.now.timeIntervalSince(t) * 1000))ms")
        guard let window = w else { return print("no window in \(state.appName)") }
        let found = inApp + aroundScreen(after: inApp.count, shown: shownArea())
        let screen = screenRect(around: window)
        let tmp = FileManager.default.temporaryDirectory
        let shot = tmp.appendingPathComponent("kite-guide-check-\(UUID().uuidString).png"), ctx = tmp.appendingPathComponent("kite-guide-check-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: shot); try? FileManager.default.removeItem(at: ctx) }
        let cap = Process()
        cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // The whole screen, as the guide sees it (the app should be in front for the picture to match).
        cap.arguments = ["-x", "-R", "\(Int(screen.minX)),\(Int(screen.minY)),\(Int(screen.width)),\(Int(screen.height))", shot.path]
        try? cap.run(); cap.waitUntilExit()
        try? describe(window, screen, found).write(to: ctx, atomically: true, encoding: .utf8)
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli)
        p.arguments = ["run", "guide", "Goal: \(goal)", "--image", shot.path, "--context", ctx.path]
        var env = ProcessInfo.processInfo.environment; env["PATH"] = Kite.path; p.environment = env
        p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let said = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let name = said.split(separator: " ").first?.split(separator: "/").last else { return print("kite run said: \(said)") }
        let run = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kite/agents/guide/runs/\(name)")
        let started = Date.now
        var result: String?
        while Date.now.timeIntervalSince(started) < 180 {
            if let st = try? String(contentsOf: run.appendingPathComponent("status"), encoding: .utf8), st.trimmingCharacters(in: .whitespacesAndNewlines) != "working" {
                result = try? String(contentsOf: run.appendingPathComponent("result.md"), encoding: .utf8); break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("guide answered in \(Int(Date.now.timeIntervalSince(started)))s: \(result ?? "nothing")")
        guard let result, let answer = parse(result) else { return }
        state.steps = answer.steps.enumerated().map { i, s in
            let c = s.target.flatMap { n in found.first { $0.n == n } }
            let (kind, thenEnter) = GuideStep.kind(s.say, given: s.kind)
            return GuideStep(id: i + 1, say: s.say, target: c?.frame, role: c?.role ?? "", kind: kind, thenEnter: thenEnter)
        }
        state.after = answer.after
        state.last = answer.done
        state.phase = state.steps.isEmpty ? .done : .showing
        state.say = answer.after
        for st in state.steps { print("\(st.id). \(st.say)\(st.target == nil ? " (not on screen)" : "")") }
        // The window with each step's ring and number, at the picture's own scale.
        if let img = NSImage(contentsOf: shot), let rep = img.representations.first {
            let k = CGFloat(rep.pixelsWide) / screen.width
            let canvas = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh), flipped: true) { _ in
                img.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
                var ringed: [CGRect] = []
                for st in state.steps {
                    guard let t = st.target else { continue }
                    let again = ringed.contains(t); ringed.append(t)
                    let r = NSRect(x: (t.minX - screen.minX) * k, y: (t.minY - screen.minY) * k, width: t.width * k, height: t.height * k).insetBy(dx: -4 * k, dy: -3 * k)
                    let ink = st.kind == .see ? RingView.infoInk : RingView.ink
                    ink.setStroke()
                    let ring = NSBezierPath(roundedRect: r, xRadius: 10 * k, yRadius: 10 * k); ring.lineWidth = 4 * k; ring.stroke()
                    let d = 26 * k, disc = NSRect(x: (again ? r.maxX - 2 * k : r.minX + 2 * k) - d / 2, y: r.minY - d / 2 + 2 * k, width: d, height: d)
                    ink.setFill(); NSBezierPath(ovalIn: disc).fill()
                    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15 * k, weight: .bold), .foregroundColor: NSColor.white]
                    let n = "\(st.id)" as NSString, sz = n.size(withAttributes: a)
                    n.draw(at: NSPoint(x: disc.midX - sz.width / 2, y: disc.midY - sz.height / 2), withAttributes: a)
                }
                return true
            }
            if let tiff = canvas.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
            }
        }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: GuideBubble(state: state).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bmp)
            try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-steps.png")))
        }
        // And with "Tell it more" open, a correction typed in it.
        state.moreOpen = true
        state.more = "Not quite, I meant the app icons in the Dock"
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        win.setContentSize(host.frame.size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bmp)
            try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-more.png")))
        }
    }

    // --guide-colors <out> (#309): a mixed guide drawn, light and dark: the panel, and an action ring beside an info ring.
    static func colorsRender(out: String) {
        dryRun = true
        state = GuideState(); state.phase = .showing; state.goal = "show me this model page"; state.last = true; state.count = 4
        state.steps = [GuideStep(id: 1, say: "Model card: what the model does and how to use it", target: nil, role: "", kind: .see),
                       GuideStep(id: 2, say: "Files: the weights and config you can download", target: nil, role: "", kind: .see),
                       GuideStep(id: 3, say: "Click Use this model to see code to run it", target: nil, role: "", kind: .click),
                       GuideStep(id: 4, say: "Type: text generation in the search box", target: nil, role: "", kind: .type)]
        for dark in [false, true] {
            let look = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: GuideBubble(state: state).environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            // Two rings as on screen: an action (the Settings colour, blinking) and an info one (blue, steady).
            let ringSize = NSSize(width: 220, height: 64), m = RingStyle.margin
            let action = RingView(frame: NSRect(x: 0, y: 0, width: ringSize.width + 2 * m, height: ringSize.height + 2 * m), inset: m, number: 3)
            let info = RingView(frame: NSRect(x: 0, y: 0, width: ringSize.width + 2 * m, height: ringSize.height + 2 * m), inset: m, number: 1, info: true)
            let W = host.frame.width + 40 + action.frame.width, H = max(host.frame.height, action.frame.height * 2 + 30) + 40
            let canvas = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H)); canvas.wantsLayer = true; canvas.appearance = look
            canvas.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
            host.frame.origin = NSPoint(x: 20, y: H - 20 - host.frame.height); canvas.addSubview(host)
            info.frame.origin = NSPoint(x: host.frame.maxX + 20, y: H - 20 - info.frame.height); canvas.addSubview(info)
            action.frame.origin = NSPoint(x: host.frame.maxX + 20, y: info.frame.minY - 30 - action.frame.height); canvas.addSubview(action)
            for (v, t) in [(info, "Model card"), (action, "Use this model")] {
                let l = NSTextField(labelWithString: t); l.font = .systemFont(ofSize: 15, weight: .medium); l.sizeToFit()
                l.frame.origin = NSPoint(x: v.frame.minX + m + 16, y: v.frame.midY - l.frame.height / 2); canvas.addSubview(l)
            }
            if !dark {  // what blinks, read off the rings' own layers
                let pulses = { (v: RingView) in v.layer?.sublayers?.contains { $0.animation(forKey: "pulse") != nil } ?? false }
                print("info ring blinks: \(pulses(info)), action ring blinks: \(pulses(action)) (Blink setting: \(RingStyle.blink))")
            }
            let win = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = look; win.contentView = canvas
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if let bmp = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
                canvas.cacheDisplay(in: canvas.bounds, to: bmp)
                try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)-\(dark ? "dark" : "light").png"))
            }
        }
        exit(0)
    }

    // --guide-308-check <out> (#308): Jason's Hugging Face run, canned. A click on the address bar merges into typing the
    // address; steps after an app switch wait; a step is crossed off when its result shows (the address reached, the text in
    // the box); a tour's parts; the panel dragged and kept on screen, its spot remembered. The panel is drawn after.
    static func check308(out: String) {
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String = "") { print((pass ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  (\(detail))")); ok = ok && pass }
        func fresh() { state = GuideState(); state.phase = .showing; state.goal = "give me a tour of hugging face models"; elements = [:]; lookedAt = nil }
        controls = [GuideControl(n: 10, role: "dockitem", label: "Safari", frame: CGRect(x: 600, y: 1380, width: 60, height: 60)),
                    GuideControl(n: 40, role: "textfield", label: "smart search field", frame: CGRect(x: 786, y: 49, width: 984, height: 31))]
        // 1. Jason's three steps, as the guide wrote them
        fresh()
        addStep(say: "Switch to Safari in the Dock", target: 10, kind: "click")
        addStep(say: "Click the address bar and go to huggingface.co/models", target: nil, kind: "click")
        addStep(say: "Type: huggingface.co/models, then press Enter", target: nil, kind: "type")
        check("after an app switch, the rest waits for the next look", state.steps.count == 1 && state.steps[0].role == "dockitem", state.steps.map(\.say).joined(separator: " | "))
        // 2. On Safari: the click on the address bar and the typing are one step, ringed on the address bar
        fresh()
        addStep(say: "Click the address bar", target: 40, kind: "click")
        addStep(say: "Type: huggingface.co/models in the address bar, then press Enter", target: 40, kind: "type")
        check("the address bar's click and typing are one step, with a ring", state.steps.count == 1 && state.steps[0].kind == .type && state.steps[0].target != nil && state.steps[0].id == 1)
        fresh()
        addStep(say: "Click the address bar and go to huggingface.co/models", target: nil, kind: "click")
        addStep(say: "Type: huggingface.co/models, then press Enter", target: nil, kind: "type")
        check("the same with no target (Jason's wording) is one step too", state.steps.count == 1)
        // 3. Crossed off by what shows
        fresh()
        addStep(say: "Type: huggingface.co/models in the address bar, then press Enter", target: 40, kind: "type")
        addStep(say: "Click Models", target: nil, kind: "click")
        crossByOutcome(url: "https://huggingface.co/", boxText: { _ in nil })
        check("not yet: the site, but not the models page", !state.steps[0].done)
        crossByOutcome(url: "https://huggingface.co/models", boxText: { _ in nil })
        check("the address reached: that step is crossed off", state.steps[0].done && !state.steps[1].done)
        fresh()
        addStep(say: "Click the search box", target: nil, kind: "click")
        state.steps.append(GuideStep(id: 2, say: "Type: huggingface.co/models", target: nil, role: "", kind: .type)); state.count = 2
        crossByOutcome(url: "https://huggingface.co/models?sort=trending", boxText: { _ in nil })
        check("the steps that led there are crossed off too", state.steps.allSatisfy(\.done))
        fresh()
        state.steps = [GuideStep(id: 1, say: "Type: Acme Notes in the App name box", target: nil, role: "", kind: .type)]; state.count = 1
        crossByOutcome(url: nil, boxText: { _ in "Acme Notes" })
        check("the box holds the text: crossed off", state.steps[0].done)
        // 4. A tour
        fresh()
        addStep(say: "Search: find a model by name", target: 40, kind: "see")
        addStep(say: "Tasks: filter models by what they do", target: nil, kind: "see")
        crossByOutcome(url: "https://huggingface.co/models", boxText: { _ in nil })
        check("a tour's parts are \"see\" steps, never crossed off by themselves", state.steps.allSatisfy { $0.kind == .see && !$0.done })
        // 5. The panel: dragged, kept on screen, remembered
        let saved = UserDefaults.standard.string(forKey: panelKey)
        UserDefaults.standard.removeObject(forKey: panelKey); state.placed = nil
        showBubble(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let p = bubble {
            let a = p.frame, m = NSPoint(x: a.midX, y: a.maxY - 10)
            panelDragged(mouse: m); panelDragged(mouse: NSPoint(x: m.x - 300, y: m.y - 200)); panelDropped()
            check("dragged: it follows the mouse", abs(p.frame.minX - (a.minX - 300)) < 1 && abs(p.frame.minY - (a.minY - 200)) < 1, "\(Int(a.minX)),\(Int(a.minY)) → \(Int(p.frame.minX)),\(Int(p.frame.minY))")
            let moved = p.frame.origin
            let v = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: p.frame.midX, y: p.frame.midY)) } ?? NSScreen.main)!.visibleFrame
            let m2 = NSPoint(x: p.frame.midX, y: p.frame.maxY - 10)
            panelDragged(mouse: m2); panelDragged(mouse: NSPoint(x: m2.x + 9000, y: m2.y + 9000)); panelDropped()
            check("dragged far: stays on the screen", v.contains(p.frame))
            panelDragged(mouse: NSPoint(x: p.frame.midX, y: p.frame.maxY - 10)); panelDragged(mouse: NSPoint(x: p.frame.midX - p.frame.minX + moved.x, y: p.frame.maxY - 10 - p.frame.minY + moved.y)); panelDropped()
            let before = p.frame
            state.placed = nil; showBubble()
            check("its spot is remembered (next look, next time)", abs(p.frame.minX - before.minX) < 1 && abs(p.frame.maxY - before.maxY) < 1 && UserDefaults.standard.string(forKey: panelKey) != nil,
                  "top-left before \(Int(before.minX)),\(Int(before.maxY)) size \(Int(before.width))x\(Int(before.height)); after \(Int(p.frame.minX)),\(Int(p.frame.maxY)) size \(Int(p.frame.width))x\(Int(p.frame.height)); aimed at \(Int(moved.x)),\(Int(moved.y))")
            state.moreOpen = true
            for dark in [false, true] {
                let host = NSHostingView(rootView: GuideBubble(state: state).environment(\.colorScheme, dark ? .dark : .light))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bmp)
                    try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)-\(dark ? "dark" : "light").png"))
                }
            }
        } else { check("the panel opens", false) }
        if let saved { UserDefaults.standard.set(saved, forKey: panelKey) } else { UserDefaults.standard.removeObject(forKey: panelKey) }
        close()
        print(ok ? "all passed" : "some failed")
        exit(ok ? 0 : 1)
    }

    // --guide-fold-check <out> (#306): a canned answer folded into canned steps, nothing on screen: a reword, a step put in,
    // a line under one, an edit aimed at a done step (ignored), and what only you know. Prints the steps and draws the panel.
    static func foldCheck(out: String) {
        dryRun = true
        state.goal = "Fill in the App domain section"; state.phase = .showing; state.runID = "check"; state.count = 3
        lastQuestion = "my privacy policy is at https://www.santarow.com/privacy, where does it go?"; controls = []
        state.steps = [GuideStep(id: 1, say: "Type: Acme Notes in the App name box", target: nil, role: "", kind: .type, done: true),
                       GuideStep(id: 2, say: "Type your home page URL in the Application home page box", target: nil, role: "", kind: .type),
                       GuideStep(id: 3, say: "Type your privacy policy URL in the privacy policy box", target: nil, role: "", kind: .type)]
        let answer = """
        {"edit": 3, "say": "Type: https://www.santarow.com/privacy in the privacy policy box", "target": null, "do": "type"}
        {"insert_after": 3, "say": "Type: https://www.santarow.com/terms in the terms of service box", "target": null, "do": "type"}
        {"note": 2, "say": "Your site's front page, e.g. https://www.santarow.com"}
        {"edit": 1, "say": "This must not change: step 1 is done", "target": null, "do": "type"}
        {"after": "Then click Save at the bottom", "done": false}
        """
        answered(answer, "")
        var ok = true
        func check(_ name: String, _ pass: Bool) { print((pass ? "PASS " : "FAIL ") + name); ok = ok && pass }
        for st in state.steps { print("  \(st.id). \(st.done ? "[done] " : "")\(st.say)\(st.note.map { "  ↳ \($0)" } ?? "")") }
        check("a done step stays as it was", state.steps.first?.say == "Type: Acme Notes in the App name box" && state.steps.first?.done == true)
        check("the step is reworded with the answer", state.steps.first { $0.id == 3 }?.say.contains("santarow.com/privacy") == true && state.steps.first { $0.id == 3 }?.value == "https://www.santarow.com/privacy")
        check("a made-up address isn't typed: no /terms step", state.steps.map(\.id) == [1, 2, 3] && !state.steps.contains { $0.say.contains("/terms") })
        check("a line under the step it's about", state.steps.first { $0.id == 2 }?.note?.contains("front page") == true)
        check("what only you know, said plainly", state.answer?.contains("Only you know the address for the terms of service box") == true)
        check("then: kept from the answer, said once", state.after == "Then click Save at the bottom" && afterLine(state.after) == "Then: click Save at the bottom")
        let inserted = put(after: 3, say: "Type: Acme Notes support in the support box", target: nil, kind: "type")
        check("a step can still be put in, numbered on", inserted && state.steps.map(\.id) == [1, 2, 3, 4])
        check("still showing, nothing started over", state.phase == .showing && state.steps.count == 4)
        state.moreOpen = true; state.more = "where do i find my policy url?"
        for dark in [false, true] {
            let host = NSHostingView(rootView: GuideBubble(state: state).environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bmp)
                try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)-\(dark ? "dark" : "light").png"))
            }
        }
        print(ok ? "all passed" : "some failed")
        exit(ok ? 0 : 1)
    }

    // --guide-ask-check <bundle id> <goal> <question> <out> <n done> (#306): the real guide on that app's window, the first
    // n steps crossed off as if you'd done them, then the question, through the same path as the ask box. Prints the steps
    // before and after, and draws the panel after, light and dark.
    static func askCheck(bundle: String, goal: String, question: String, out: String, done: Int) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        else { print("not running: \(bundle)"); exit(1) }
        target = app
        // Waits by checking again later on the main queue: the guide's own replies come that way, so a loop here would starve them.
        @MainActor func wait(_ until: @escaping @MainActor () -> Bool, _ limit: Double, then: @escaping @MainActor () -> Void) {
            let t0 = Date.now
            @MainActor func tick() {
                if until() || Date.now.timeIntervalSince(t0) > limit { return then() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { tick() } }
            }
            tick()
        }
        func show(_ title: String) {
            print("== \(title)")
            for st in state.steps { print("  \(st.id). \(st.done ? "[done] " : "")\(st.say)\(st.target == nil ? " (no ring)" : "")\(st.note.map { "\n     ↳ \($0)" } ?? "")") }
            if let a = state.answer { print("  ? \(a)") }
            if !state.after.isEmpty { print("  then: \(state.after)") }
        }
        state.goal = goal
        look(first: true)
        wait({ (state.phase == .showing && !state.streaming) || state.phase == .failed || state.phase == .done }, 90) {
        guard state.phase == .showing else { print("no steps: \(state.say)"); exit(1) }
        for i in state.steps.indices where i < done { state.steps[i].done = true }
        show("steps (first \(done) crossed off)")
        let t0 = Date.now
        state.more = question; tell()
        wait({ !state.answering }, 90) {
        print("answered in \(String(format: "%.1f", Date.now.timeIntervalSince(t0))) s")
        show("after: \(question)")
        state.moreOpen = true
        for dark in [false, true] {
            let host = NSHostingView(rootView: GuideBubble(state: state).environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bmp)
                try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)-\(dark ? "dark" : "light").png"))
            }
        }
        close()
        exit(0)
        } }
    }

    // --guide-shot <bundle id> <goal> <out.png> (#277): a picture for the website, of Guide me on a real app. Only that
    // app's window is captured (by its window number, so nothing beside or over it gets in), the real guide answers
    // from it, and its rings are drawn on it; the steps panel sits beside the window. Anything in the window showing
    // the Mac's owner (their name, "Apple Account") is covered with the sidebar's own colour. Nothing is clicked.
    static func siteShot(bundle: String, goal: String, out: String, dark: Bool) {
        // Not this process: shooting the dev build's own Settings is another copy of the same app.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }),
              let root = Kite.root else { return print("not running: \(bundle)") }
        state = GuideState(); state.goal = goal; state.appName = app.localizedName ?? bundle
        _ = AgentStore.shared; AgentStore.shared.refresh()
        let (w, found) = read(app.processIdentifier)
        guard let window = w else { return print("no window in \(state.appName)") }
        // The number of the window just read, for a capture of it alone: the one at its exact place and size. Never the
        // app's biggest window, which can be another one of the owner's (a second Safari window showed his dashboard).
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
        func off(_ d: [String: Any]) -> CGFloat {  // AX and the window list both measure from the top left
            let b = d[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            return abs((b["X"] ?? 0) - window.minX) + abs((b["Y"] ?? 0) - window.minY) + abs((b["Width"] ?? 0) - window.width) + abs((b["Height"] ?? 0) - window.height)
        }
        guard let best = mine.min(by: { off($0) < off($1) }), off(best) < 4, let num = best[kCGWindowNumber as String] as? Int else {
            return print("the window read isn't on screen to capture alone")
        }
        let tmp = FileManager.default.temporaryDirectory
        let shot = tmp.appendingPathComponent("kite-guide-shot-\(UUID().uuidString).png"), ctx = tmp.appendingPathComponent("kite-guide-shot-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: shot); try? FileManager.default.removeItem(at: ctx) }
        let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        cap.arguments = ["-x", "-o", "-l", "\(num)", shot.path]
        try? cap.run(); cap.waitUntilExit()
        let inWindow = found.filter { window.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        try? describe(window, window, inWindow).write(to: ctx, atomically: true, encoding: .utf8)
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli)
        p.arguments = ["run", "guide", "Goal: \(goal)", "--image", shot.path, "--context", ctx.path]
        var env = ProcessInfo.processInfo.environment; env["PATH"] = Kite.path; p.environment = env
        p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let said = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let name = said.split(separator: " ").first?.split(separator: "/").last else { return print("kite run said: \(said)") }
        let run = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kite/agents/guide/runs/\(name)")
        let started = Date.now
        var result: String?
        while Date.now.timeIntervalSince(started) < 180 {
            if let st = try? String(contentsOf: run.appendingPathComponent("status"), encoding: .utf8), st.trimmingCharacters(in: .whitespacesAndNewlines) != "working" {
                result = try? String(contentsOf: run.appendingPathComponent("result.md"), encoding: .utf8); break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let result, let answer = parse(result) else { return print("no answer") }
        state.steps = answer.steps.enumerated().map { i, s in
            let c = s.target.flatMap { n in inWindow.first { $0.n == n } }
            let (kind, thenEnter) = GuideStep.kind(s.say, given: s.kind)
            return GuideStep(id: i + 1, say: s.say, target: c?.frame, role: c?.role ?? "", kind: kind, thenEnter: thenEnter)
        }
        state.after = answer.after; state.last = answer.done; state.phase = .showing
        for st in state.steps { print("\(st.id). \(st.say)\(st.target == nil ? " (not in the window)" : "")") }
        // What shows the owner, to cover: their name or "Apple Account", with the row's whole width to the sidebar's edge.
        let me = NSFullUserName()
        let owner = found.filter { !me.isEmpty && $0.label.contains(me) || $0.label.localizedCaseInsensitiveContains("Apple Account") }.map(\.frame)
        guard let img = NSImage(contentsOf: shot), let rep = img.representations.first else { return print("no capture") }
        let k = CGFloat(rep.pixelsWide) / window.width
        // The steps panel, drawn as on screen.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: GuideBubble(state: state).environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let pw = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        pw.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let panelRep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        if let panelRep { host.cacheDisplay(in: host.bounds, to: panelRep) }
        let pSize = NSSize(width: host.bounds.width * k, height: host.bounds.height * k), gap = 28 * k
        let size = NSSize(width: CGFloat(rep.pixelsWide) + gap + pSize.width + 24 * k, height: max(CGFloat(rep.pixelsHigh), pSize.height + 48 * k))
        let canvas = NSImage(size: size, flipped: true) { _ in
            img.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
            for o in owner {  // covered with the colour just left of the row, the sidebar's
                let r = NSRect(x: 8 * k, y: (o.minY - window.minY - 8) * k, width: (o.maxX - window.minX + 12) * k, height: (o.height + 16) * k)
                let sample = NSBitmapImageRep(data: img.tiffRepresentation!)?.colorAt(x: Int(4 * k), y: Int(r.midY)) ?? .windowBackgroundColor
                sample.setFill(); NSBezierPath(roundedRect: r, xRadius: 8 * k, yRadius: 8 * k).fill()
            }
            var ringed: [CGRect] = []
            for st in state.steps {
                guard let t = st.target else { continue }
                let again = ringed.contains(t); ringed.append(t)
                let r = NSRect(x: (t.minX - window.minX) * k, y: (t.minY - window.minY) * k, width: t.width * k, height: t.height * k).insetBy(dx: -4 * k, dy: -3 * k)
                let ink = st.kind == .see ? RingView.infoInk : RingView.ink
                if !again {  // as on screen: a second step on the same control adds its number, not a ring over the first's
                    ink.setStroke()
                    let ring = NSBezierPath(roundedRect: r, xRadius: 10 * k, yRadius: 10 * k); ring.lineWidth = 4 * k; ring.stroke()
                }
                let d = 26 * k, disc = NSRect(x: (again ? r.maxX - 2 * k : r.minX + 2 * k) - d / 2, y: r.minY - d / 2 + 2 * k, width: d, height: d)
                ink.setFill(); NSBezierPath(ovalIn: disc).fill()
                NSColor.white.setStroke(); let edge = NSBezierPath(ovalIn: disc); edge.lineWidth = 2 * k; edge.stroke()
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15 * k, weight: .bold), .foregroundColor: NSColor.white]
                let n = "\(st.id)" as NSString, sz = n.size(withAttributes: a)
                n.draw(at: NSPoint(x: disc.midX - sz.width / 2, y: disc.midY - sz.height / 2), withAttributes: a)
            }
            if let panelRep {
                let pi = NSImage(size: host.bounds.size); pi.addRepresentation(panelRep)
                NSGraphicsContext.saveGraphicsState()
                let sh = NSShadow(); sh.shadowBlurRadius = 18 * k; sh.shadowOffset = NSSize(width: 0, height: -4 * k); sh.shadowColor = NSColor.black.withAlphaComponent(0.25); sh.set()
                pi.draw(in: NSRect(x: CGFloat(rep.pixelsWide) + gap, y: 24 * k, width: pSize.width, height: pSize.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        if let tiff = canvas.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out)); print("wrote \(out), covered \(owner.count) owner row(s)")
        }
    }

    // ---------- Drawing ----------

    // Accessibility frames are top-left based; Cocoa's are bottom-left of the main screen.
    private static func cocoa(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    // A numbered red ring on each step still to do; a done one's ring goes away (it's crossed off in the list).
    private static func showRings() {
        if dryRun { return }
        clearRings()
        var ringed: [CGRect] = []
        for step in state.steps where !step.done {
            guard let target = step.target else { continue }
            let again = ringed.contains(target)  // a second step on the same control: its number on the other corner
            ringed.append(target)
            let t = cocoa(target).insetBy(dx: -4, dy: -3)  // snug, so rows next to each other keep apart
            let m = RingStyle.margin
            let p = NSPanel(contentRect: t.insetBy(dx: -m, dy: -m), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)  // above the steps panel: a ring is never hidden by it
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true  // your click goes through to the real control
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = RingView(frame: NSRect(origin: .zero, size: p.frame.size), inset: m, number: step.id, right: again, info: step.kind == .see)
            p.orderFrontRegardless()
            rings.append(p)
        }
    }
    // Settings › Guide me changed the rings' colour, shape or blink: the ones showing are drawn again (#271).
    static func restyle() { if !rings.isEmpty { showRings() } }

    private static func clearRings() {
        if dryRun { return }
        rings.forEach { $0.orderOut(nil) }
        rings = []
    }

    // Where the panel goes: top right, unless that covers a ring; then the first corner (or the right
    // edge's middle) that covers none. Each new look starts top right again (#250, Jason: "the box can
    // be out of the way if its blocking something like move down etc? and then move back at the next scan").
    static func spot(for size: NSSize, screen: NSRect? = nil, rings: [NSRect]? = nil) -> NSPoint {
        let v = screen ?? NSScreen.main?.visibleFrame ?? .zero, m: CGFloat = 16
        let busy = rings ?? state.steps.filter { !$0.done }.compactMap { $0.target.map { cocoa($0).insetBy(dx: -14, dy: -14) } }
        let spots = [NSPoint(x: v.maxX - size.width - m, y: v.maxY - size.height - m),   // top right
                     NSPoint(x: v.maxX - size.width - m, y: v.minY + m),                  // bottom right
                     NSPoint(x: v.minX + m, y: v.minY + m),                               // bottom left
                     NSPoint(x: v.minX + m, y: v.maxY - size.height - m),                 // top left
                     NSPoint(x: v.maxX - size.width - m, y: v.midY - size.height / 2)]    // right, middle
        return spots.first { o in !busy.contains { $0.intersects(NSRect(origin: o, size: size)) } } ?? spots[0]
    }

    // The steps, top right of the screen, out of the way of the app you're working in.
    private static var placing = false
    static let panelKey = "guide.panelTop"
    // Dragging the steps panel by its header or background (#308): it follows the mouse and stays on the screen under it;
    // its top-left is kept (state.placed, and saved). Buttons and the box work as before: a drag starts only after 3 points.
    private static var panelDrag: (mouse: NSPoint, origin: NSPoint)?
    static func panelDragged(mouse m: NSPoint) {
        guard let p = bubble else { return }
        if panelDrag == nil { panelDrag = (m, p.frame.origin) }
        guard let d = panelDrag else { return }
        let size = p.frame.size
        let v = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: d.origin, size: size)
        let o = NSPoint(x: min(max(d.origin.x + m.x - d.mouse.x, v.minX), v.maxX - size.width), y: min(max(d.origin.y + m.y - d.mouse.y, v.minY), v.maxY - size.height))
        placing = true; p.setFrameOrigin(o); placing = false
        state.placed = NSPoint(x: o.x, y: o.y + size.height)
    }
    static func panelDropped() {
        guard panelDrag != nil else { return }
        panelDrag = nil
        if let t = state.placed { UserDefaults.standard.set(NSStringFromPoint(t), forKey: panelKey) }
    }
    private static func showBubble() {
        if dryRun { return }
        let host = NSHostingView(rootView: GuideBubble(state: state))
        host.sizingOptions = [.intrinsicContentSize]
        let p = bubble ?? {
            let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)  // key: the "Tell it more" box types
            p.level = .screenSaver
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Drag it anywhere by its background (#250, Jason: "maybe this prompt window can be moved or
            // minimzied?"); it stays there until the next look.
            p.isMovableByWindowBackground = false  // the panel's own drag moves it (#308); SwiftUI took the background's
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard !placing, let f = bubble?.frame else { return }
                    state.placed = NSPoint(x: f.minX, y: f.maxY)
                }
            }
            bubble = p
            return p
        }()
        p.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if state.placed == nil, let saved = UserDefaults.standard.string(forKey: panelKey) { state.placed = NSPointFromString(saved) }  // last time's spot
        var origin = state.placed.map { NSPoint(x: $0.x, y: $0.y - size.height) } ?? spot(for: size)  // dragged: keep its top-left
        if let v = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: origin.x + 10, y: origin.y + size.height - 10)) } ?? NSScreen.main)?.visibleFrame {
            origin = NSPoint(x: min(max(origin.x, v.minX), v.maxX - size.width), y: min(max(origin.y, v.minY), v.maxY - size.height))  // on screen
        }
        placing = true
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        placing = false
        p.orderFrontRegardless()
    }
    static func minimize(_ on: Bool) {
        state.minimized = on
        showBubble()
    }
}

// How the rings look (#271, Settings › Guide me): a colour (red unless you pick another), a rounded box that hugs
// the control or a circle around it, and the blink (#251, Jason: "it TRULY is REDNOSE"), on unless you turn it off.
enum RingStyle {
    static let colors: [(key: String, label: String, color: NSColor)] = [
        ("red", "Red", .systemRed), ("orange", "Orange", .systemOrange), ("yellow", "Yellow", .systemYellow), ("green", "Green", .systemGreen),
        ("blue", "Blue", .systemBlue), ("purple", "Purple", .systemPurple), ("pink", "Pink", .systemPink)]
    static let colorKey = "guide.ringColor", shapeKey = "guide.ringShape", blinkKey = "guide.blink"
    static var color: NSColor { let k = UserDefaults.standard.string(forKey: colorKey); return colors.first { $0.key == k }?.color ?? .systemRed }
    static var circle: Bool { UserDefaults.standard.string(forKey: shapeKey) == "circle" }
    static var blink: Bool { UserDefaults.standard.object(forKey: blinkKey) as? Bool ?? true }
    // Room around the control for the ring and its glow; a circle reaches further out than a box.
    static var margin: CGFloat { circle ? 44 : 22 }
}

// A blinking ring with the step's number on its top-left corner. It only draws; clicks pass through.
final class RingView: NSView {
    static var ink: NSColor { RingStyle.color }
    let inset: CGFloat
    // Info (#309, Jason: "use color to differentiate between 'highlight info' and blinking red 'action to link'"): a tour's
    // part, only pointed out, is calm blue and never blinks. Actions keep the ring colour and blink of Settings › Guide me.
    static let infoInk = NSColor.systemBlue
    init(frame: NSRect, inset: CGFloat, number: Int, right: Bool = false, info: Bool = false) {
        self.inset = inset
        let ink = info ? Self.infoInk : Self.ink
        super.init(frame: frame)
        wantsLayer = true
        let shape = CAShapeLayer()
        let box = bounds.insetBy(dx: inset, dy: inset)
        if RingStyle.circle {  // an oval around the control, out past its corners (capped, so a long box stays sane)
            shape.path = CGPath(ellipseIn: box.insetBy(dx: -min(box.width * 0.2, 40), dy: -min(box.height * 0.2 + 4, 40)), transform: nil)
        } else {
            shape.path = CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)
        }
        shape.fillColor = ink.withAlphaComponent(0.08).cgColor
        shape.strokeColor = ink.cgColor
        shape.lineWidth = 4
        shape.shadowColor = ink.cgColor
        shape.shadowRadius = 8
        shape.shadowOpacity = 0.8
        shape.shadowOffset = .zero
        if !right { layer?.addSublayer(shape) }  // a second step on the same control: its number only, the ring's already there
        if RingStyle.blink, !right, !info {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            shape.add(pulse, forKey: "pulse")
        }
        // The number, in a red disc on the ring's top-left corner (steady, so it's easy to read).
        let d: CGFloat = 26
        let badge = CALayer()
        badge.frame = CGRect(x: (right ? box.maxX - 2 : box.minX + 2) - d / 2, y: box.maxY - d / 2 - 2, width: d, height: d)
        badge.backgroundColor = ink.cgColor
        badge.cornerRadius = d / 2
        badge.borderColor = NSColor.white.cgColor
        badge.borderWidth = 2
        let label = CATextLayer()
        label.string = "\(number)"
        label.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        label.fontSize = 15
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 0, y: (d - 19) / 2, width: d, height: 19)
        badge.addSublayer(label)
        layer?.addSublayer(badge)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct GuideAskView: View {
    @ObservedObject var state: GuideState
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "hand.point.up.left").font(.title2).foregroundStyle(Color.pink)
                // Paste Claude's instructions here too (#250): several lines are fine.
                TextField("What do you want to do in \(state.appName)?", text: $state.goal, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($typing)
                    .onSubmit { Guide.begin() }
                    .onKeyPress(.escape) { Guide.close(); return .handled }
            }
            Text("\(AppName.shown) numbers every step on the screen. You do the clicking. Esc to cancel.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { typing = true }
    }
}

// The steps in red, each crossed off when done (click a row to cross it off or back on yourself).
// The copy icon as Claude's messages show it: two squares, no button around it; on hover a soft rounded
// highlight and the tooltip "Copy"; for a moment after a click, a checkmark.
struct CopyIcon: View {
    let copied: Bool
    var hover = false
    let action: () -> Void
    @StateObject private var hovering = HoverState()  // this toolchain has no @State
    private var over: Bool { hovering.on }

    var body: some View {
        Button(action: action) {
            Image(systemName: copied ? "checkmark" : "square.on.square")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(over || hover || copied ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(over || hover ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering.on = $0 }
        .animation(.easeOut(duration: 0.12), value: over)
        .help(copied ? "Copied" : "Copy")
    }
}

struct GuideBubble: View {
    @ObservedObject var state: GuideState
    @FocusState private var typing: Bool

    var body: some View {
        if state.minimized { pill } else { panel }
    }

    // Minimized: a small pill that says how many are left; a click opens the steps again.
    private var pill: some View {
        Button { Guide.minimize(false) } label: {
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left").foregroundStyle(Color.red)
                if state.phase == .looking { ThinkingDots() }
                Text(pillText).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Show the steps")
    }
    private var pillText: String {
        switch state.phase {
        case .showing: let n = state.steps.filter { !$0.done }.count; return "Guide · \(n) left"
        case .looking: return "Guide · \(state.say)"
        case .done: return "Guide · done"
        default: return "Guide"
        }
    }

    // A Type step (#264): its text in a box you click to copy, and the copy icon at the end of the line, as Claude's
    // own messages have it (Jason: "just use the icon as a button ... hovering says copy"). Fill is gone ("a bit off").
    @ViewBuilder private func typeStep(_ step: GuideStep, _ value: String) -> some View {
        let say = step.say as NSString, r = say.range(of: value)
        let before = r.location == NSNotFound ? "Type:" : say.substring(to: r.location).trimmingCharacters(in: .whitespaces)
        let after = r.location == NSNotFound ? "" : say.substring(from: r.location + r.length).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"”’',").union(.whitespaces))
        let copied = state.copied == step.id
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(before.trimmingCharacters(in: CharacterSet(charactersIn: "\"“‘'"))).font(.body.weight(.medium)).foregroundStyle(Color.red)
                .textSelection(.enabled)
            Text(value).font(.system(.body, design: .monospaced).weight(.medium)).foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.red.opacity(copied ? 0.2 : 0.1), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { Guide.copy(step.id) }
                .help("Click to copy")
            CopyIcon(copied: copied, hover: state.copyHover == step.id) { Guide.copy(step.id) }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
        }
        if !after.isEmpty {
            Text(after).font(.body.weight(.medium)).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // Ask (#306, Jason: "add like a chat bubble to expand and collapse a textbox so i can send to it"): one way in, for a
    // question about a step or a "not quite" alike. At the end of the button row, right above where the box opens (#309,
    // Jason: "move this bubble ... to around here, i think its better since its closer to where the window is opening").
    private var askButton: some View {
        Button { Guide.openMore() } label: { Image(systemName: state.moreOpen ? "bubble.left.fill" : "bubble.left").font(.body) }
            .buttonStyle(.borderless).help(state.moreOpen ? "Close the question box" : "Ask about a step, or say what you meant")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.point.up.left").foregroundStyle(Color.red)
                Text(state.goal).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { Guide.minimize(true) } label: { Image(systemName: "minus") }.buttonStyle(.borderless).help("Make it small")
                Button { Guide.close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            switch state.phase {
            case .showing:
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(state.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // Its number crosses it off by hand (or back); the words are yours to select (#264).
                            Button { Guide.cross(step.id) } label: {
                                Text("\(step.id)").font(.callout.bold()).foregroundStyle(.white)
                                    .frame(width: 22, height: 22).background(step.done ? Color.secondary : (step.kind == .see ? Color.blue : Color.red), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help(step.done ? "Not done yet" : "Done: cross it off")
                            VStack(alignment: .leading, spacing: 4) {
                                if !step.done, let v = step.value { typeStep(step, v) } else {
                                    Text(step.say).font(.body.weight(.medium))
                                        .strikethrough(step.done, color: step.kind == .see ? .blue : .red)
                                        .foregroundStyle(step.done ? Color.secondary : (step.kind == .see ? Color.blue : Color.red))  // info blue, action red (#309)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                                // Said, not left silent (#250): this one has no ring, so click its number when it's done.
                                if let note = step.note {  // the answer to your question about this step (#306)
                                    Label { Text(note).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) } icon: { Image(systemName: "text.bubble") }
                                        .font(.callout).foregroundStyle(.primary)
                                }
                                if step.target == nil && !step.done {
                                    Text("No ring: \(AppName.shown) couldn't find this on screen. Click its number when done.")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if state.answering {
                    HStack(spacing: 6) { ThinkingDots(); Text("Looking at your question").font(.caption).foregroundStyle(.secondary) }
                }
                if let a = state.answer {  // what only you know, said plainly (#306)
                    Label { Text(a).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) } icon: { Image(systemName: "person.crop.circle.badge.questionmark") }
                        .font(.callout).foregroundStyle(Color.orange)
                }
                if state.streaming {  // more of its steps on the way
                    HStack(spacing: 6) { ThinkingDots(); Text("More steps coming").font(.caption).foregroundStyle(.secondary) }
                }
                if !state.after.isEmpty {
                    Text(Guide.afterLine(state.after)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if state.steps.contains(where: { $0.kind == .see }), state.steps.contains(where: { $0.kind != .see }) {  // a mixed guide: the key (#309)
                    Text("Blue rings point things out; red rings are for you to click.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(state.steps.allSatisfy { $0.kind == .see } ? "A tour of this page: each ring is one part. Click a number to tick it off."
                     : state.last ? "Each one is crossed off as you do it." : "Each one is crossed off as you do it; when they all are, it looks again.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Look again") { Guide.next() }.keyboardShortcut(.defaultAction)
                    Button("Done") { Guide.close() }
                    Spacer()
                    askButton
                }
                .font(.callout)
            case .looking:
                // Like Claude's own: three pulsing dots, the seconds so far, what it's doing (Jason: "even this is good too").
                TimelineView(.periodic(from: state.since, by: 1)) { t in
                    HStack(spacing: 8) {
                        ThinkingDots()
                        Text("\(max(0, Int(t.date.timeIntervalSince(state.since))))s · \(state.say)").foregroundStyle(.secondary)
                    }
                }
            case .done:
                Label { Text(state.say).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                HStack(spacing: 14) { Button("Close") { Guide.close() }; Spacer(); askButton }.font(.callout)
            case .failed:
                Label { Text(state.say).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                HStack(spacing: 14) {
                    Button("Try again") { state.phase = .showing; Guide.next() }
                    Button("Close") { Guide.close() }
                    Spacer()
                    askButton
                }
                .font(.callout)
            case .asking:
                EmptyView()
            }
            // The ask box, from the chat bubble up top (#306): a question about a step folds its answer into the steps;
            // "not quite, I meant…" looks again with your words. Return sends, Escape folds it away.
            if state.moreOpen, state.phase == .showing || state.phase == .done || state.phase == .failed {
                HStack(spacing: 8) {
                    TextField(state.phase == .showing ? "Ask about a step, or say what you meant" : "Say what you meant", text: $state.more)
                        .textFieldStyle(.roundedBorder)
                        .focused($typing)
                        .onSubmit { Guide.tell() }
                        .onKeyPress(.escape) { state.moreOpen = false; return .handled }
                    Button { Guide.tell() } label: { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                        .buttonStyle(.borderless).disabled(state.more.trimmingCharacters(in: .whitespaces).isEmpty || state.answering)
                        .help("Send (Return)")
                }
                .onAppear { typing = true }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)  // drag it by any part that isn't a button or the box (#308)
            .onChanged { _ in Guide.panelDragged(mouse: NSEvent.mouseLocation) }
            .onEnded { _ in Guide.panelDropped() })
    }
}

// Three small orange dots pulsing one after another, like Claude's "thinking".
struct ThinkingDots: View {
    static let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
    var body: some View {
        TimelineView(.animation) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Self.orange).frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * (1 + sin(s * 4 - Double(i) * 2.1)) / 2)  // a third of a turn apart: one is always bright
                }
            }
        }
    }
}

// --time-guide <bundle id> "<goal>": Guide me on that app as you'd use it (its screen read while you'd type,
// a warm claude), timed from Return: the instant ring, the first step, and all of them. Nothing on screen.
extension Guide {
    static func time(bundle: String, goal: String) {
        _ = NSApplication.shared
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return print("not running") }
        dryRun = true; target = app
        func spin(_ limit: Double, _ until: () -> Bool) { let t = Date.now; while !until(), Date.now.timeIntervalSince(t) < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
        start()  // the ask panel's moment: the screen is read and a claude made ready
        askPanel?.orderOut(nil)
        spin(25) { WarmAgent.guide.isReady && pre != nil }
        state.goal = goal
        let t0 = Date.now
        begin()
        let instant = state.steps.isEmpty ? nil : Date.now.timeIntervalSince(t0)
        var first: Double?
        spin(60) {
            if first == nil, streamed > 0 { first = Date.now.timeIntervalSince(t0) }
            return state.phase != .looking && !state.streaming
        }
        let all = Date.now.timeIntervalSince(t0)
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f s", $0) } ?? "none" }
        print("\(goal): instant ring \(f(instant)), first step \(f(first)), all \(f(all)): " + state.steps.map { "\($0.id) \($0.say)\($0.target == nil ? " (no ring)" : "")" }.joined(separator: " | "))
        WarmAgent.guide.stop()
    }
}

import AppKit
import SwiftUI

// Enhance (#253, Jason: "dont you have the enhance pre-prompt window, can you make it"; the plan is
// santarow ops/prompt-builder-plan.md): write a rough ask, take pictures with Highlight while it's open
// (they attach here as 🖼 1, 🖼 2 instead of going to Claude), and Enhance has your own Claude rewrite it as
// a clear prompt: the goal, the context, the constraints, what done looks like. In your voice, nothing
// made up. Edit the result beside your words, then Send pastes it and the pictures into Claude's box.
// Each picture has its own note (Jason: "the images pasted in each have their own text box and i can type
// in it"): pictures and notes top left, scrolling when there are many; the ask bottom left.

struct EnhanceShot: Identifiable {
    let id = UUID()
    let png: Data
    var note = ""
}

@MainActor
final class EnhanceModel: ObservableObject {
    @Published var draft = ""
    @Published var shots: [EnhanceShot] = []
    var pictures: [Data] { shots.map(\.png) }
    @Published var result = ""
    @Published var working = false
    @Published var since = Date.now
    @Published var problem: String?
    @Published var note: String?      // which model answered, when it wasn't the one picked (#302)
    @Published var expanded: UUID?    // the picture shown big over the window, if any
    @Published var hovering: UUID?    // the picture under the pointer: it shows the zoom-in mark
    private var watch: Timer?

    func attach(_ png: Data) {
        shots.append(EnhanceShot(png: png))
        Log.line("enhance: picture \(shots.count) attached")
    }

    func enhance() {
        let ask = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty, !working else { return }
        working = true; since = .now; problem = nil; note = nil
        let text = Enhance.message(ask: ask, notes: shots.map(\.note))
        let picked = Enhance.picked
        // Already found missing this session: straight to the closest one, with the note.
        if Enhance.missing.contains(picked.arg), let back = picked.fallback {
            return run(text, model: back.arg) { run in
                if self.finish(run) { self.note = Enhance.fallbackNote(picked, back) }
            }
        }
        // On the claude started ahead when there is one (#254), and the answer read from the run's own folder.
        run(text, model: nil) { run in
            guard let run, run.status == "done" else {
                // Your Claude Code can't run the model picked (#302, Jason: "incase ppl didnt update their claude"): the
                // closest one it has answers instead, and the note says so. Never a silent failure.
                if run?.errorKind == "model_not_found" { Enhance.missing.insert(picked.arg) }
                if run?.errorKind == "model_not_found", let back = picked.fallback {
                    Log.line("enhance: \(picked.name) not in this Claude Code; \(back.name) instead")
                    return self.run(text, model: back.arg) { again in
                        if self.finish(again) {
                            self.note = Enhance.fallbackNote(picked, back)
                        } else if again?.errorKind == "model_not_found" {
                            self.problem = "Your Claude Code can't run \(picked.name) or \(back.name). Update Claude Code, then try again."
                        }
                    }
                }
                if run?.errorKind == "model_not_found" {
                    self.problem = "Your Claude Code doesn't have \(picked.name) yet. Update Claude Code, or pick another model in Settings › Magic."
                    return
                }
                _ = self.finish(run)
                return
            }
            _ = self.finish(run)
        }
    }
    // One run, on the picked model (nil) or another; `done` gets its final state, or nil when it couldn't start.
    private func run(_ text: String, model: String?, done: @escaping @MainActor (RunState?) -> Void) {
        WarmAgent.start(.enhance, text, png: Enhance.sheet(pictures), context: nil, follow: nil, model: model) { id in
            guard let id else { return done(nil) }
            RunState.watch(agent: "enhance", id: id) { run in done(run) }
        }
    }
    // The answer in, or the problem said; true when there's an answer.
    private func finish(_ run: RunState?) -> Bool {
        working = false
        WarmAgent.enhance.prepare()  // ready for the next Enhance
        guard let run else { problem = "Couldn't start your Claude."; return false }
        if run.status == "done", let r = run.result.map(Enhance.unwrap), !r.isEmpty {
            result = r
            Log.line("enhance: done in \(Int(Date.now.timeIntervalSince(since) * 1000))ms")
            return true
        }
        problem = run.plainProblem ?? "Your Claude didn't answer. Try again."
        return false
    }
}

@MainActor
enum Enhance {
    static let model = EnhanceModel()
    private static var window: NSWindow?
    private static var pill: NSPanel?
    // Open, or folded into its pill: either way Highlight's pictures come here.
    static var isOpen: Bool { window?.isVisible == true || pill?.isVisible == true }

    // Not a switch (#272, Jason: "this isnt supposed to be a feature flag"): always there in Penpal; in Workshop
    // alongside Guide me, as before.
    static var available: Bool { Flavor.current == .penpal || Features.on(.guide) }

    // The model Enhance asks (#293): Settings › Enhance. Sonnet 5.5 unless you pick another, as 1.0.1 did (the agent's own,
    // agents/enhance/agent.json). Times from the bench, warm, 5 asks × 3 rounds interleaved, on the tagged prompt (#296,
    // bench/agent-speed/results-2026-10-07-enhance-prompt.json): medians Haiku 2.6 s (thinking off), Sonnet 3.4 s, Opus 3.4 s.
    static let models: [(id: String, name: String, note: String)] = [
        // Opus, Sonnet, Haiku (Jason: "lets also order this as Opus, Sonnet, and Haiku"); the default stays Sonnet 5.5.
        ("opus", "Opus 5.5", "About 3 to 5 seconds. The most careful: it says when a picture doesn't match your ask"),
        ("sonnet", "Sonnet 5.5", "About 4 to 5 seconds. Clear prompts. The default"),  // claude-sonnet-5-5: 4.2 s median (#302)
        ("haiku-5-5", "Haiku 5.5", "About 3 seconds. Quick, plainer prompts"),  // claude-haiku-5-5 at effort low (#302)
        ("haiku", "Haiku 4.5", "About 3 seconds. For older Claude Code"),  // thinking off, as 1.0.2 shipped it (#296)
    ]
    // What Enhance sends (#296): the ask and the notes in tags, so even a small model sees text to rewrite, not a
    // question to answer (agents/enhance/persona.md says the rest, with an example).
    static func message(ask: String, notes: [String]) -> String {
        var t = "<ask>\n\(ask)\n</ask>"
        if !notes.isEmpty {
            t += "\n\n<notes>\n" + notes.enumerated().map { i, n in
                "🖼 \(i + 1): " + (n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no note)" : n)
            }.joined(separator: "\n") + "\n</notes>\n\n\(notes.count) picture\(notes.count == 1 ? "" : "s") in the image, labelled 🖼 1… ."
        }
        return t + "\n\nRewrite the ask as their prompt for Claude. Don't answer it. Only <prompt>…</prompt>."
    }
    // The prompt from inside <prompt>…</prompt> (the whole answer when a model leaves the tags off), with any em dash
    // made a comma: the persona says never, and a small model sometimes does anyway.
    nonisolated static func unwrap(_ answer: String) -> String {
        var t = answer
        if let a = answer.range(of: "<prompt>"), let b = answer.range(of: "</prompt>", range: a.upperBound..<answer.endIndex) {
            t = String(answer[a.upperBound..<b.lowerBound])
        }
        return t.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: "—", with: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let modelKey = "enhance.model"
    static var pickedModel: String {
        let m = UserDefaults.standard.string(forKey: modelKey) ?? "sonnet"
        return models.contains { $0.id == m } ? m : "sonnet"
    }
    // What goes to kite's --model (#302): each by its full id, so the model that answers is the one the pane names. Claude
    // Code 2.1.282's own aliases lag: "haiku" is Haiku 4.5 and "sonnet" is Claude Sonnet 5 ("opus" is Opus 5.5 already).
    // Saved picks keep their meaning: "haiku" is still Haiku 4.5 (Jason: "add haiku 5.5 low effort … as another option in,
    // incase ppl didnt update their claude"); Haiku 5.5 is the new "haiku-5-5". Each has a fallback for a Claude Code that
    // can't run it: Claude Code's own alias for that family (Haiku 4.5 by its full id for Haiku 5.5). Bench (bench/agent-speed/results-2026-10-07-haiku-5-5.json): at
    // effort low (agents/enhance/agent.json) 2.8 s median against 4.5's 2.6 s with thinking off, p75 3.9 s against 5.1 s;
    // it thought on 3 of 15 asks (at most 262 tokens); 15 of 15 rewritten, none answered.
    // `key`: the real id, for its fallback; `arg` is what's sent (the same, but for a test's stand-in).
    struct Choice: Sendable {
        let name: String, arg: String; var key = ""
        var fallback: Choice? {
            guard let f = Enhance.fallbacks[key.isEmpty ? arg : key] else { return nil }
            return ProcessInfo.processInfo.environment["KITE_FAKE_FALLBACK"].map { Choice(name: f.name, arg: $0) } ?? f
        }
    }
    static let args = ["sonnet": "claude-sonnet-5-5", "opus": "claude-opus-5-5", "haiku-5-5": "claude-haiku-5-5", "haiku": "claude-haiku-4-5-20251001"]
    nonisolated static let fallbacks: [String: Choice] = [
        "claude-sonnet-5-5": Choice(name: "Claude Code's Sonnet", arg: "sonnet"),
        "claude-opus-5-5": Choice(name: "Claude Code's Opus", arg: "opus"),
        "claude-haiku-5-5": Choice(name: "Haiku 4.5", arg: "claude-haiku-4-5-20251001"),
        "claude-haiku-4-5-20251001": Choice(name: "Claude Code's Haiku", arg: "haiku"),
    ]
    // KITE_FAKE_MODEL / KITE_FAKE_FALLBACK (tests only): a model id no Claude Code has, in place of the pick or its
    // fallback, to see what someone with an older Claude Code sees.
    static var picked: Choice {
        let arg = args[pickedModel] ?? pickedModel
        return Choice(name: models.first { $0.id == pickedModel }?.name ?? pickedModel,
                      arg: ProcessInfo.processInfo.environment["KITE_FAKE_MODEL"] ?? arg, key: arg)
    }
    static var pickedModelArg: String { picked.arg }
    static var missing = Set<String>()  // models this Claude Code said it can't run, this session
    static func fallbackNote(_ picked: Choice, _ back: Choice) -> String {
        "\(back.name) answered. Your Claude Code doesn't have \(picked.name) yet. Update Claude Code, or pick another model in Settings › Magic."
    }
    static func pick(_ m: String) {
        UserDefaults.standard.set(m, forKey: modelKey)
        missing.removeAll()  // a new pick: try it
        Log.line("enhance: model \(m)")
        WarmAgent.enhance.prepare()  // the ready claude, started again on the new model
    }

    static func open() {
        let w = window ?? {
            let w = FoldingWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            w.title = "Enhance"
            w.isReleasedWhenClosed = false
            w.level = .floating  // stays up while you take pictures in other apps
            w.contentView = NSHostingView(rootView: EnhanceView(model: model))
            w.addTitlebarAccessoryViewController(foldAccessory())
            w.center()
            // Esc puts a big picture away, whatever has the keyboard (a note box usually does).
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.keyCode == 53 else { return e }
                let closed = MainActor.assumeIsolated {
                    guard model.expanded != nil, window?.isKeyWindow == true else { return false }
                    model.expanded = nil
                    return true
                }
                return closed ? nil : e
            }
            window = w
            return w
        }()
        pill?.orderOut(nil)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        WarmAgent.enhance.prepare()  // a claude ready while you write (#254)
        Log.line("enhance: open")
    }

    // Fold, in the title bar's top right corner (#286, Jason: "lets also move the fold button or that icon to the top
    // right corner, where it intuitivdly belongs"): an icon on its own, as macOS draws a title bar's own buttons.
    static func foldAccessory() -> NSTitlebarAccessoryViewController {
        let b = NSButton(image: NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Fold")!,
                         target: FoldTarget.shared, action: #selector(FoldTarget.fold))
        b.bezelStyle = .accessoryBarAction
        b.showsBorderOnlyWhileMouseInside = true
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Fold"
        b.setAccessibilityLabel("Fold")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))  // the title bar's height, so it sits level with the window's buttons
        b.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(b)
        NSLayoutConstraint.activate([b.centerYAnchor.constraint(equalTo: box.centerYAnchor), b.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
                                     b.widthAnchor.constraint(equalToConstant: 26), b.heightAnchor.constraint(equalToConstant: 22)])
        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .trailing
        acc.view = box
        return acc
    }
    @MainActor private final class FoldTarget: NSObject {
        static let shared = FoldTarget()
        @objc func fold() { Enhance.fold() }
    }

    // Highlight's picture, while this is open: it goes here, not into Claude.
    static func attach(_ png: Data) {
        model.attach(png)
        if pill?.isVisible == true { return }  // folded: the pill's count goes up, the window stays out of the way
        window?.orderFrontRegardless()
    }

    // Folded (#256, Jason: "add a way to minimize or collapse the window on a MacBook Air so it doesn't take up
    // so much space while still letting me keep taking screenshots"): the window becomes a small floating pill,
    // Dock-style, that you can drag. Pictures you take still come here and the pill counts them; a click
    // opens the window again with everything as it was.
    static func fold() {
        guard let w = window else { return }
        let p = pill ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = false  // the pill's own drag moves it (#297), clamped to the screen
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: EnhancePill(model: model))
            host.sizingOptions = [.intrinsicContentSize]
            p.contentView = host
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
                MainActor.assumeIsolated { if let f = pill?.frame { UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: "enhance.pill") } }
            }
            pill = p
            return p
        }()
        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? NSSize(width: 220, height: 56)
        // Where you last put it, else where the window's top-right corner was.
        let top = UserDefaults.standard.string(forKey: "enhance.pill").map(NSPointFromString) ?? NSPoint(x: w.frame.maxX - size.width, y: w.frame.maxY)
        let at = onScreen(NSPoint(x: top.x, y: top.y - size.height), size: size, near: top)  // a screen since unplugged: brought back
        p.setFrame(NSRect(origin: at, size: size), display: true)
        w.orderOut(nil)
        p.orderFrontRegardless()
        Log.line("enhance: folded (\(model.shots.count) pictures)")
    }

    // Dragging the pill (#297, Jason: "allow the minimized enahcen to be movable, i do like the shape"): from anywhere
    // on it, it follows the mouse and stays on the screen under it; a press without a drag opens Enhance, as before.
    // Its place is its own ("enhance.pill", saved as it moves); the window keeps its own, so unfolding opens it there.
    private static var pillDrag: (mouse: NSPoint, origin: NSPoint)?
    static func pillDragged(mouse m: NSPoint) {
        guard let p = pill else { return }
        if pillDrag == nil { pillDrag = (m, p.frame.origin) }
        guard let d = pillDrag else { return }
        p.setFrameOrigin(onScreen(NSPoint(x: d.origin.x + m.x - d.mouse.x, y: d.origin.y + m.y - d.mouse.y), size: p.frame.size, near: m))
    }
    static func pillDropped(mouse m: NSPoint) {
        guard let d = pillDrag else { return }
        pillDrag = nil
        if hypot(m.x - d.mouse.x, m.y - d.mouse.y) < 3 { pill?.setFrameOrigin(d.origin); open() }  // a click, not a drag
    }
    // Kept inside the visible part (no menu bar, no Dock) of the screen under `near`.
    private static func onScreen(_ o: NSPoint, size: NSSize, near: NSPoint) -> NSPoint {
        let v = (NSScreen.screens.first { $0.frame.contains(near) } ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: o, size: size)
        return NSPoint(x: min(max(o.x, v.minX), v.maxX - size.width), y: min(max(o.y, v.minY), v.maxY - size.height))
    }

    // Into Claude's box, in order: the prompt (enhanced, or your ask as you wrote it), then each picture under
    // its 🖼 label (Lines between pictures applies, as with Highlight) with its note after the label.
    static func send() {
        let enhanced = model.result.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = enhanced.isEmpty ? model.draft.trimmingCharacters(in: .whitespacesAndNewlines) : enhanced
        let shots = model.shots
        guard !prompt.isEmpty || !shots.isEmpty else { return }
        window?.orderOut(nil); pill?.orderOut(nil)
        Paster.pastePicturesAndText(shots.map(\.png), text: sendText(prompt, shots.map(\.note), lines: Paster.linesBetween)) { result in
            Log.line("enhance: sent \(shots.count) pictures (\(result))")
        }
        Paster.continuePictures(after: shots.count)  // a picture taken next is 🖼 n+1, as if Highlight had pasted these
        model.draft = ""; model.result = ""; model.shots = []
    }

    // All the words in one paste: the prompt, then each picture's label and note, Lines between pictures apart.
    static func sendText(_ prompt: String, _ notes: [String], lines: Int) -> String {
        let labels = notes.enumerated().map { i, n in
            (i == 0 ? "" : lines == 0 ? " " : String(repeating: "\n", count: lines))  // 0 lines: a space, so a note doesn't run into the next label
                + "\u{1F5BC} \(i + 1) " + n.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined()
        return [prompt, labels].filter { !$0.isEmpty }.joined(separator: notes.isEmpty ? "" : "\n\n")
    }

    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.result, forType: .string)
        NSSound(named: "Pop")?.play()
    }

    // The pictures as one image for your Claude (a run takes one), each under its 🖼 label.
    static func sheet(_ pictures: [Data]) -> Data? {
        let images = pictures.compactMap { NSImage(data: $0) }
        guard !images.isEmpty else { return nil }
        let width = min(1600, images.map(\.size.width).max() ?? 800), label: CGFloat = 44
        let heights = images.map { $0.size.height * min(1, width / max($0.size.width, 1)) }
        let total = heights.reduce(0, +) + label * CGFloat(images.count)
        let sheet = NSImage(size: NSSize(width: width, height: total), flipped: true) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: total).fill()
            var y: CGFloat = 0
            for (i, img) in images.enumerated() {
                ("\u{1F5BC} \(i + 1)" as NSString).draw(at: NSPoint(x: 8, y: y + 6), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.black])
                y += label
                let s = min(1, width / max(img.size.width, 1))
                img.draw(in: NSRect(x: 0, y: y, width: img.size.width * s, height: heights[i]))
                y += heights[i]
            }
            return true
        }
        guard let tiff = sheet.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}

struct EnhanceView: View {
    @ObservedObject var model: EnhanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pictures").font(.headline)
                    pictures
                    Text("Your ask").font(.headline).padding(.top, 6)
                    TextEditor(text: $model.draft)
                        .font(.system(size: Self.textSize)).scrollContentBackground(.hidden).padding(6)
                        .fieldBox(radius: 8)
                        .overlay(alignment: .topLeading) {
                            if model.draft.isEmpty {
                                Text("Write it rough: what you want, and anything Claude should know.")
                                    .font(.system(size: Self.textSize)).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                            }
                        }
                        .frame(height: 150)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Enhanced").font(.headline)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $model.result)
                            .font(.body).scrollContentBackground(.hidden).padding(6)
                            .fieldBox(radius: 8)
                        if model.working {
                            TimelineView(.periodic(from: model.since, by: 1)) { t in
                                HStack(spacing: 8) {
                                    ThinkingDots()
                                    Text("\(max(0, Int(t.date.timeIntervalSince(model.since))))s · Thinking").foregroundStyle(.secondary)
                                }
                                .padding(12)
                            }
                        } else if model.result.isEmpty {
                            Text(model.problem ?? "Your Claude rewrites it here: the goal, the context, the constraints, what done looks like. In your words, nothing made up. You can edit it.")
                                .foregroundStyle(model.problem == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                                .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                        }
                    }
                    if let n = model.note {  // another model answered (#302)
                        Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { model.enhance() } label: { Label("Enhance", systemImage: "wand.and.stars") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.working || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("⌘↩").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { Enhance.copy() }.disabled(model.result.isEmpty)
                Button { Enhance.send() } label: { Label("Send to Claude", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.working || (model.result.isEmpty && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.shots.isEmpty))
                    .help(model.result.isEmpty ? "Sends your ask as you wrote it, with the pictures" : "Sends the enhanced prompt, with the pictures")
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 380)  // fits a 13-inch MacBook Air beside Claude
        .overlay { if let id = model.expanded, let shot = model.shots.first(where: { $0.id == id }) { preview(shot) } }
    }

    static let thumb = CGSize(width: 120, height: 80)
    static let textSize: CGFloat = 15  // the notes and the ask alike (#256, Jason: "make the text in the picture notes bigger")
    static var zoomCursor: NSCursor {
        if #available(macOS 15, *) { return .zoomIn }
        return .pointingHand
    }

    // Quick Look style: the picture big over the window. A click anywhere, Esc, or the picture's own
    // thumbnail again puts it away.
    private func preview(_ shot: EnhanceShot) -> some View {
        let n = (model.shots.firstIndex { $0.id == shot.id } ?? 0) + 1
        return ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 8) {
                if let img = NSImage(data: shot.png) {
                    Image(nsImage: img).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 20)
                }
                Text("\u{1F5BC} \(n)" + (shot.note.isEmpty ? "" : ": " + shot.note.prefix(120)))
                    .font(.callout).foregroundStyle(.white).lineLimit(2)
                Text("Click anywhere or press Esc to close").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .padding(40)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.expanded = nil }
        .onExitCommand { model.expanded = nil }
        .focusable()
        .focusEffectDisabled()
    }

    // One row per picture: the picture, its label, its own note, and remove. Scrolls when there are many.
    private var pictures: some View {
        Group {
            if model.shots.isEmpty {
                Text("Hold \(Highlighter.shared.keysLabel) and draw while this is open: each picture lands here as 🖼 1, 🖼 2, with a box for a note on it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                    .padding(10)
                    .fieldBox(radius: 8, subtle: true)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach($model.shots) { $shot in
                            let i = model.shots.firstIndex { $0.id == shot.id } ?? 0
                            HStack(alignment: .top, spacing: 10) {
                                // The picture, its label on it; a click shows it big (Jason: "allow me to click on the
                                // image to expand and away etc to collapse").
                                Button { model.expanded = model.expanded == shot.id ? nil : shot.id } label: {
                                    ZStack(alignment: .bottomLeading) {
                                        if let img = NSImage(data: shot.png) {
                                            Image(nsImage: img).resizable().scaledToFill()
                                                .frame(width: Self.thumb.width, height: Self.thumb.height).clipped()
                                        }
                                        Text("\u{1F5BC} \(i + 1)").font(.caption.weight(.semibold))
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                            .foregroundStyle(.white).padding(4)
                                    }
                                    .frame(width: Self.thumb.width, height: Self.thumb.height)
                                    // Like Claude's own attachments: hovering shows a magnifying glass with + (the
                                    // pointer turns into one too), and a click opens the picture big.
                                    .overlay {
                                        if model.hovering == shot.id {
                                            ZStack {
                                                Color.black.opacity(0.25)
                                                Image(systemName: "plus.magnifyingglass").font(.system(size: 22, weight: .semibold))
                                                    .foregroundStyle(.white).shadow(radius: 3)
                                            }
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { inside in
                                    if inside { model.hovering = shot.id; Self.zoomCursor.push() }
                                    else { if model.hovering == shot.id { model.hovering = nil }; NSCursor.pop() }
                                }
                                .help("Show \u{1F5BC} \(i + 1) big")
                                // A real text area exactly the picture's height (Jason: "bigger and longer by height",
                                // "but not extending past the image height"): wraps, Return is a new line, longer
                                // text scrolls inside.
                                TextEditor(text: $shot.note)
                                    .font(.system(size: Self.textSize)).scrollContentBackground(.hidden).padding(4)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Self.thumb.height)
                                    .fieldBox(radius: 6)
                                    .overlay(alignment: .topLeading) {
                                        if shot.note.isEmpty {
                                            Text("Note on \u{1F5BC} \(i + 1) (optional)").font(.system(size: Self.textSize)).foregroundStyle(.tertiary)
                                                .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                                        }
                                    }
                                Button { model.shots.removeAll { $0.id == shot.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove \u{1F5BC} \(i + 1)")
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: .infinity)
                .fieldBox(radius: 8, subtle: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// --render-enhance "<rough ask>" <out-prefix>: the window before (your ask, a picture) and after (your Claude's
// real rewrite), drawn to <out>-before.png and <out>-after.png. Runs the real agent; nothing is pasted.
private final class KeyLook: NSWindow {  // a render's window, drawn as if it had the keyboard
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
@MainActor
func renderEnhance(ask: String, out: String, pictures: Int = 1, run: Bool = true) {
    _ = NSApplication.shared
    let m = Enhance.model
    m.draft = ask
    let notes = ["the Deploy button is greyed out here, even after I pushed a fresh commit. It was blue yesterday and I could click it.",
                 "this is the error it shows when I try from the command line instead:\nError: build step failed\nexit code 1",
                 "", "the setting I think is wrong. Node 18 is picked, but the project says 20 in package.json, so maybe that's it? Not sure.",
                 "after a reload", ""]
    let colors: [NSColor] = [.systemTeal, .systemOrange, .systemIndigo, .systemPink, .systemGreen, .systemBrown]
    // Stand-in pictures: small drawn cards, so the rows and the sheet have something to show. With KITE_SITE_DEMO set
    // (#277, the website's pictures), a made-up hosting dashboard with its Deploy button greyed out and a terminal
    // with the error: a demo, nothing from anyone's Mac.
    let demo = ProcessInfo.processInfo.environment["KITE_SITE_DEMO"] != nil
    func demoCard(_ n: Int) -> NSImage {
        NSImage(size: NSSize(width: 480, height: 300), flipped: true) { r in
            if n % 2 == 0 {
                NSColor.white.setFill(); r.fill()
                NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: r.width, height: 44).fill()
                let t: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.black]
                let g: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.gray]
                ("acme  /  my-site" as NSString).draw(at: NSPoint(x: 18, y: 13), withAttributes: t)
                ("Production" as NSString).draw(at: NSPoint(x: 18, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.black])
                ("main  ·  pushed 2 min ago  ·  a1b2c3d" as NSString).draw(at: NSPoint(x: 18, y: 110), withAttributes: g)
                NSColor(white: 0.85, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 18, y: 150, width: 120, height: 36), xRadius: 8, yRadius: 8).fill()
                ("Deploy" as NSString).draw(at: NSPoint(x: 52, y: 159), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor(white: 0.55, alpha: 1)])
                ("Last deploy failed  ·  yesterday" as NSString).draw(at: NSPoint(x: 18, y: 210), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemRed])
            } else {
                NSColor(white: 0.1, alpha: 1).setFill(); r.fill()
                let m: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor(white: 0.9, alpha: 1)]
                for (i, line) in ["$ npm run deploy", "> my-site@1.0.0 deploy", "> build && upload", "", "Error: build step failed", "exit code 1"].enumerated() {
                    var a = m; if line.hasPrefix("Error") { a[.foregroundColor] = NSColor.systemRed }
                    (line as NSString).draw(at: NSPoint(x: 18, y: 22 + CGFloat(i) * 24), withAttributes: a)
                }
            }
            return true
        }
    }
    for n in 0..<pictures {
        let card = demo ? demoCard(n) : NSImage(size: NSSize(width: 400, height: 240), flipped: false) { r in
            colors[n % colors.count].setFill(); r.fill()
            ("Screen \(n + 1)" as NSString).draw(at: NSPoint(x: 20, y: 110), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white])
            return true
        }
        if let t = card.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
            m.attach(png)
            m.shots[m.shots.count - 1].note = notes[n % notes.count]
        }
    }
    if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }  // drawn in dark (#273 follow-up)
    if !run, !ask.isEmpty, m.result.isEmpty {  // not run: a stand-in answer, so the Enhanced box shows text too
        m.result = "Goal: the Deploy button works again.\n\nContext: since yesterday's push the button in \u{1F5BC} 1 stays grey.\n\nDone looks like: a fresh commit deploys with one click."
    }
    func draw(_ name: String) {
        // Drawn as the key window (#284): off screen it never is, and "Send to Claude" came out grey instead of blue.
        // With its title bar (#286): the traffic lights, "Enhance" and Fold in the corner; 820×560 in all, as before.
        let host = NSHostingView(rootView: EnhanceView(model: m).background(Color(nsColor: .windowBackgroundColor)).environment(\.controlActiveState, .key))
        let w = KeyLook(contentRect: NSRect(x: 0, y: 0, width: 820, height: 528), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Enhance"
        w.contentView = host
        w.addTitlebarAccessoryViewController(Enhance.foldAccessory())
        if CommandLine.arguments.contains("--dark") { w.appearance = NSAppearance(named: .darkAqua) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let frame = host.superview ?? host  // the window's frame view: title bar and content together
        // A render is never the active app, so macOS draws its title bar as a window in the back: grey buttons and title.
        // The title in its front colour, and the three buttons painted over in theirs, as the window looks in use.
        func titles(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? [] + v.subviews.flatMap(titles) }
        let title = titles(frame).first { $0.stringValue == "Enhance" }
        let titleAt = title.map { frame.convert($0.bounds, from: $0) }, titleFont = title?.font
        if title != nil { w.titleVisibility = .hidden; RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        if let bmp = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: bmp)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
            let lights: [(NSWindow.ButtonType, NSColor, NSColor)] = [(.closeButton, NSColor(red: 1, green: 0.373, blue: 0.341, alpha: 1), NSColor(red: 0.886, green: 0.275, blue: 0.247, alpha: 1)),
                                                                     (.miniaturizeButton, NSColor(red: 0.996, green: 0.737, blue: 0.180, alpha: 1), NSColor(red: 0.882, green: 0.631, blue: 0.086, alpha: 1)),
                                                                     (.zoomButton, NSColor(red: 0.157, green: 0.784, blue: 0.251, alpha: 1), NSColor(red: 0.102, green: 0.671, blue: 0.161, alpha: 1))]
            for (kind, fill, edge) in lights {
                guard let b = w.standardWindowButton(kind), let sv = b.superview else { continue }
                let r = frame.convert(sv.convert(b.frame, to: nil), from: nil)
                let d = min(r.width, r.height) - 1, dot = NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
                fill.setFill(); NSBezierPath(ovalIn: dot).fill()
                edge.setStroke(); let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25)); ring.lineWidth = 0.5; ring.stroke()
            }
            if let at = titleAt, let font = titleFont {
                w.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
                    let sz = ("Enhance" as NSString).size(withAttributes: attrs)
                    ("Enhance" as NSString).draw(at: NSPoint(x: at.minX + 2, y: at.midY - sz.height / 2), withAttributes: attrs)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)-\(name).png"))
        }
    }
    draw("before")
    do {  // folded: the pill
        let host = NSHostingView(rootView: EnhancePill(model: m).padding(20).background(Color(red: 0.3, green: 0.32, blue: 0.4)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bmp)
            try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)-pill.png"))
        }
    }
    if !m.shots.isEmpty {  // the pointer over the second picture, then the first shown big
        m.hovering = m.shots[min(1, m.shots.count - 1)].id
        draw("hover")
        m.hovering = nil
        m.expanded = m.shots[0].id
        draw("expanded")
        m.expanded = nil
    }
    guard run else { return }
    m.enhance()
    let started = Date.now
    while m.working, Date.now.timeIntervalSince(started) < 180 { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    print("enhance answered in \(Int(Date.now.timeIntervalSince(started)))s\(m.problem.map { " (problem: \($0))" } ?? "")\(m.note.map { " (note: \($0))" } ?? ""):\n\(m.result)")
    draw("after")
}

// --send-check: what Send would paste, without touching Claude or your clipboard: the words (at 1 and 0 lines
// between pictures), and 10 pictures written as files to a private pasteboard the way Finder copies them,
// read back in order.
@MainActor
func sendCheck() {
    print("== words, 1 line between pictures:")
    print(Enhance.sendText("Fix the deploy. See 🖼 1 to 🖼 3.", ["greyed out button", "", "the error\nexit code 1"], lines: 1).debugDescription)
    print("== words, 0 lines:")
    print(Enhance.sendText("Fix it.", ["a", "b"], lines: 0).debugDescription)
    print("== no pictures:")
    print(Enhance.sendText("Just words.", [], lines: 1).debugDescription)
    let t0 = Date.now
    let pngs: [Data] = (0..<10).compactMap { n in
        let img = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { r in
            NSColor(hue: CGFloat(n) / 10, saturation: 0.6, brightness: 0.9, alpha: 1).setFill(); r.fill(); return true }
        return img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }
    let made = Date.now.timeIntervalSince(t0)
    let t1 = Date.now
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("penpal-send-check-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let urls = pngs.enumerated().compactMap { i, png -> URL? in
        let u = dir.appendingPathComponent("picture-\(i + 1).png"); return (try? png.write(to: u)) != nil ? u : nil }
    let board = NSPasteboard(name: NSPasteboard.Name("penpal-send-check"))
    board.clearContents()
    board.writeObjects(urls as [NSURL])
    let back = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    let ms = Int(Date.now.timeIntervalSince(t1) * 1000)
    let inOrder = back.map(\.lastPathComponent) == (1...10).map { "picture-\($0).png" }
    let valid = back.allSatisfy { NSImage(contentsOf: $0) != nil }
    print("== 10 pictures (1200x800, made in \(Int(made * 1000))ms): \(back.count) file items, in order: \(inOrder), all readable PNGs: \(valid), types: \(board.pasteboardItems?.first?.types.map(\.rawValue) ?? []), written and read back in \(ms)ms")
    board.releaseGlobally()
    try? FileManager.default.removeItem(at: dir)
}

// --pill-check (#297): on the live pill, drags and a click the way the gesture reports them (mouse points; no
// synthetic events): it follows the mouse, stays on the screen, keeps its own place apart from the window's, and a
// press without a drag opens the window where it was. Your saved pill place is put back afterwards.
extension Enhance {
    static func pillCheck() {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  (" + detail + ")")); if !ok { failed += 1 } }
        func spin(_ s: Double = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let saved = UserDefaults.standard.string(forKey: "enhance.pill")
        UserDefaults.standard.removeObject(forKey: "enhance.pill")
        open(); spin(1)
        guard let w = window else { print("FAIL no window"); exit(1) }
        let windowAt = w.frame
        fold(); spin(0.5)
        guard let p = pill, p.isVisible else { print("FAIL no pill"); exit(1) }
        check("folded: the pill shows and the window hides", p.isVisible && !w.isVisible)
        let a = p.frame, start = NSPoint(x: a.midX, y: a.midY)
        pillDragged(mouse: start)  // the press: the gesture's first report, at the press point (minimumDistance 0)
        for k in 1...20 { pillDragged(mouse: NSPoint(x: start.x - CGFloat(k) * 10, y: start.y - CGFloat(k) * 6)) }  // 200 left, 120 down
        pillDropped(mouse: NSPoint(x: start.x - 200, y: start.y - 120)); spin()
        let b = p.frame
        check("a drag moves it with the mouse", abs(b.minX - (a.minX - 200)) < 1 && abs(b.minY - (a.minY - 120)) < 1,
              "from \(Int(a.minX)),\(Int(a.minY)) to \(Int(b.minX)),\(Int(b.minY))")
        check("the shape is the same", b.size == a.size, "\(Int(b.width))×\(Int(b.height))")
        check("its place is saved as it moves", UserDefaults.standard.string(forKey: "enhance.pill").map(NSPointFromString) == NSPoint(x: b.minX, y: b.maxY))
        check("still folded after a drag", p.isVisible && !w.isVisible)
        let v = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: b.midX, y: b.midY)) } ?? NSScreen.main)!.visibleFrame
        let s2 = NSPoint(x: b.midX, y: b.midY)
        pillDragged(mouse: s2); pillDragged(mouse: NSPoint(x: s2.x - 5000, y: s2.y + 5000)); pillDropped(mouse: NSPoint(x: s2.x - 5000, y: s2.y + 5000)); spin()
        check("dragged far off: it stays on the screen", v.contains(p.frame), "pill \(Int(p.frame.minX)),\(Int(p.frame.minY)) in \(Int(v.minX))…\(Int(v.maxX)) × \(Int(v.minY))…\(Int(v.maxY))")
        // Back to a spot in the middle, then a click.
        let c = NSPoint(x: p.frame.midX, y: p.frame.midY)
        pillDragged(mouse: c); pillDragged(mouse: NSPoint(x: c.x + 300, y: c.y - 200)); pillDropped(mouse: NSPoint(x: c.x + 300, y: c.y - 200)); spin()
        let placed = p.frame
        let m = NSPoint(x: placed.midX, y: placed.midY)
        pillDragged(mouse: m); pillDragged(mouse: NSPoint(x: m.x + 1, y: m.y)); pillDropped(mouse: NSPoint(x: m.x + 1, y: m.y)); spin(0.5)
        check("a click (1 pt of movement) opens Enhance", w.isVisible && !p.isVisible)
        check("the window opens where it was, not where the pill went", w.frame == windowAt, "window \(Int(w.frame.minX)),\(Int(w.frame.minY))")
        fold(); spin(0.5)
        check("folding again: the pill comes back where you left it", p.frame.origin == placed.origin, "\(Int(p.frame.minX)),\(Int(p.frame.minY))")
        open(); spin(0.3); w.close()
        if let saved { UserDefaults.standard.set(saved, forKey: "enhance.pill") } else { UserDefaults.standard.removeObject(forKey: "enhance.pill") }
        print(failed == 0 ? "all passed" : "\(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

// The window's own minimize (yellow) button folds it into the pill instead of the Dock, so Highlight's
// pictures keep coming here and it stays one click away.
final class FoldingWindow: NSWindow {
    override func miniaturize(_ sender: Any?) { MainActor.assumeIsolated { Enhance.fold() } }
}

// Folded Enhance: the app's icon, "Enhance" and how many pictures it holds. A click opens it again.
struct EnhancePill: View {
    @ObservedObject var model: EnhanceModel
    var body: some View {
        HStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 34, height: 34) }
            VStack(alignment: .leading, spacing: 1) {
                Text("Enhance").font(.headline)
                Text(model.shots.isEmpty ? "no pictures yet" : "\(model.shots.count) picture\(model.shots.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .contentShape(Capsule())
        // Drag from anywhere to move it (#297); a press without a drag opens Enhance. Screen coordinates: the view's
        // own shift as the panel moves under the mouse.
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in Enhance.pillDragged(mouse: NSEvent.mouseLocation) }
            .onEnded { _ in Enhance.pillDropped(mouse: NSEvent.mouseLocation) })
        .help("Open Enhance. Drag to move")
    }
}

// --send-sim: Send's real order and waits (Paster.runSend) against a pretend Claude whose box shows pictures
// after a delay, or never, or can't be read. Counts what ends up in it: never more pictures than were sent.
@MainActor
func sendSim() -> Bool {
    _ = NSApplication.shared
    // A stand-in Claude: each picture shows by its box a moment after its paste (or late, or can't be read).
    @MainActor final class FakeClaude {
        var shown = 0, pastes = 0, words = false, order: [String] = []
        func land(after d: Double) { DispatchQueue.main.asyncAfter(deadline: .now() + d) { MainActor.assumeIsolated { self.shown += 1 } } }
    }
    struct Case { let name: String; let n: Int; let shows: Double; let readable: Bool }
    let cases = [
        Case(name: "1 picture", n: 1, shows: 0.05, readable: true),
        Case(name: "2 pictures (Jason's Send)", n: 2, shows: 0.05, readable: true),
        Case(name: "10 pictures", n: 10, shows: 0.05, readable: true),
        Case(name: "2 pictures, Claude slow to show them (0.8 s)", n: 2, shows: 0.8, readable: true),
        Case(name: "2 pictures, Claude's box can't be read", n: 2, shows: 0.05, readable: false),
    ]
    var ok = true
    for c in cases {
        let fake = FakeClaude()
        var done: String?
        let t0 = Date.now
        let io = Paster.SendIO(
            pasteOne: { i in fake.pastes += 1; fake.order.append("p\(i + 1)"); fake.land(after: c.shows) },
            pasteText: { fake.order.append("text"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { fake.words = true } } },
            size: { c.readable ? 10 + fake.shown * 3 : nil },
            textLanded: { fake.words })
        Paster.runSend(pictures: c.n, text: true, io: io) { note in done = note }
        while done == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        let took = Date.now.timeIntervalSince(t0)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))  // anything still on its way lands
        let want = (1...c.n).map { "p\($0)" } + ["text"]
        let pass = fake.pastes == c.n && fake.order == want && fake.shown == c.n && fake.words
        ok = ok && pass
        print(String(format: "%@ %@ → one pass: %d pastes then the words, %d in Claude, %.2f s%@",
                     pass ? "PASS" : "FAIL", c.name, fake.pastes, fake.shown, took, done!))
    }
    print(ok ? "all passed: one pass, each picture once, then the words" : "SOME FAILED")
    return ok
}

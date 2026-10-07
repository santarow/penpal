import AppKit
import SwiftUI

// 5.1: a screenshot of part of the screen, pasted as an image into Claude's message box.
// Not sent: you add words and press Enter. Two modes, picked in the menu bar:
//   Select area        drag a box; that box is the picture
//   Draw to highlight  draw around something; the picture is that spot and its
//                      surroundings, with your drawing in it
// Start it by holding Control and Option (let go before dragging to cancel), or with
// the camera button on the dock (click without dragging to cancel).
@MainActor
final class Highlighter: ObservableObject {
    // Circle + ask (Workshop's Labs): a question box for the picture instead of pasting it. True when it took it.
    static func askInstead(_ png: Data, under rect: NSRect) -> Bool {
        return false
    }
    enum Mode: String, CaseIterable {
        case area, draw
        var label: String { self == .area ? "Select area" : "Draw to highlight" }
        var icon: String { self == .area ? "camera.viewfinder" : "pencil.tip.crop.circle" }
    }

    static let shared = Highlighter()

    @Published var enabled = true
    @Published var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "") ?? .area {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "captureMode") }
    }
    @Published private(set) var canCapture = Access.canCaptureScreen
    // Circle + ask: a question box under the capture instead of sending it straight away.
    @Published var askAfterCapture = UserDefaults.standard.bool(forKey: "askAfterCapture") {
        didSet { UserDefaults.standard.set(askAfterCapture, forKey: "askAfterCapture") }
    }
    // In the question box: listen right away, send on a pause, read the answer aloud.
    @Published var askWithVoice = UserDefaults.standard.bool(forKey: "askWithVoice") {
        didSet { UserDefaults.standard.set(askWithVoice, forKey: "askWithVoice") }
    }

    // The keys you hold to start (⌃⌥ unless you pick others), and what ends a highlight: letting go
    // of the mouse (one drag), or of the keys (draw as many strokes as you like first).
    static let triggers: [(flags: NSEvent.ModifierFlags, label: String)] = [
        ([.control, .option], "⌃⌥"), ([.control, .shift], "⌃⇧"), ([.option, .shift], "⌥⇧"),
        ([.control, .command], "⌃⌘"), ([.option, .command], "⌥⌘")]
    @Published var trigger = UInt(UserDefaults.standard.object(forKey: "highlight.keys") as? Int ?? Int(NSEvent.ModifierFlags([.control, .option]).rawValue)) {
        didSet { UserDefaults.standard.set(Int(trigger), forKey: "highlight.keys") }
    }
    @Published var finishOnKeys = UserDefaults.standard.bool(forKey: "highlight.finishOnKeys") {
        didSet { UserDefaults.standard.set(finishOnKeys, forKey: "highlight.finishOnKeys") }
    }
    var triggerFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: trigger) }
    var keysLabel: String { Self.triggers.first { $0.flags == triggerFlags }?.label ?? Self.describe(triggerFlags) }

    private var panels: [NSPanel] = []
    private var dragging = false
    private var fromButton = false  // started by the dock button, so no keys are held

    private init() {
        Access.whenTrusted { self.install() }
    }
    // For the diagnostic in Settings → Screenshots: is the key monitor in, and when did it last see
    // your keys (a monitor added while macOS didn't trust the app never gets events).
    @Published private(set) var monitorsInstalled = false
    @Published private(set) var keysSeenAt: Date?
    private var monitors: [Any] = []

    func requestCapture() {
        Permissions.shared.fix()
        canCapture = Access.canCaptureScreen
    }
    func permissionsChanged() { canCapture = Access.canCaptureScreen }
    private var toldNeed = false

    // The dock's camera button.
    func startFromButton() {
        guard panels.isEmpty else { return }
        guard Access.canCaptureScreen else { return requestCapture() }
        fromButton = true
        begin()
    }

    // Re-adds every monitor (called when macOS starts trusting the app, or from the diagnostic).
    func install() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        guard Flavor.current.has(.capture) else { return }  // the highlight keys are Penpal's
        let add: (Any?) -> Void = { if let m = $0 { self.monitors.append(m) } }
        add(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { self.flagsChanged(event.modifierFlags) }
        })
        add(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { self.flagsChanged(event.modifierFlags) }
            return event
        })
        // Esc stops a highlight at any point, even mid-drag or started from the dock. Any other key
        // while ⌃⌥ is held is someone's shortcut, not a highlight: take the dim away.
        let onKey: (NSEvent) -> Void = { e in
            MainActor.assumeIsolated {
                guard !self.panels.isEmpty else { return }
                if e.keyCode == 53 { self.cancel() } else if !self.dragging, !self.fromButton { self.end() }
            }
        }
        add(NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: onKey))
        add(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in onKey(e); return e.keyCode == 53 && !self.panels.isEmpty ? nil : e })
        monitorsInstalled = monitors.count == 4
        Log.line("screenshot keys: monitor \(monitorsInstalled ? "in" : "not in") (\(Permissions.controlName) \(AXIsProcessTrusted() ? "on" : "off"))")
    }

    // Exactly your keys (⌃⌥ unless you picked others), the moment all are down, like ⇧⌘4's crosshairs.
    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let mods = flags.intersection([.command, .option, .control, .shift])
        let held = mods == triggerFlags
        if held { keysSeenAt = .now }
        if !mods.isDisjoint(with: triggerFlags) || !panels.isEmpty {
            Log.line("flags \(Highlighter.describe(mods)) held=\(held) panels=\(panels.count) dragging=\(dragging)")
        }
        if held, enabled, Features.on(.capture), panels.isEmpty, !Access.canCaptureScreen {
            // The keys work but macOS won't let us see the screen: say so once, don't just do nothing.
            Permissions.shared.check()
            if !toldNeed { toldNeed = true; tellNeed() }
        } else if held, enabled, Features.on(.capture), panels.isEmpty, Access.canCaptureScreen {
            begin()
        } else if !held, finishOnKeys, !fromButton, !panels.isEmpty {
            // Finish on letting go of the keys: whatever's drawn or boxed so far is the picture.
            if let view = panels.compactMap({ $0.contentView as? SelectionView }).first(where: { $0.drawn != nil }), let rect = view.drawn {
                finish(rect, in: view)
            } else {
                end()
            }
        } else if !held, !dragging, !fromButton {
            end()
        }
    }

    private func tellNeed() {
        let a = NSAlert()
        a.messageText = "Screenshots need Screen Recording"
        a.informativeText = "Turn on \(AppName.shown) in System Settings → Privacy & Security → Screen & System Audio Recording. macOS may ask you to quit and reopen \(AppName.shown) after."
        a.addButton(withTitle: "Open System Settings"); a.addButton(withTitle: "Not Now")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { Permissions.shared.fix() }
    }

    // One dimmed, click-catching panel per screen.
    private func begin() {
        cancelled = false
        finishing = false
        let mode = self.mode
        let byKeys = finishOnKeys && !fromButton
        let hint = (mode == .area ? "Drag to select an area" : "Draw around what you mean")
            + (fromButton ? ". Click to cancel." : byKeys ? ", then let go of \(keysLabel). Esc cancels." : ". Let go of \(keysLabel) to cancel.")
        panels = NSScreen.screens.map { screen in
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            let view = SelectionView(mode: mode, hint: hint)
            view.holdToFinish = byKeys
            view.onStart = { self.dragging = true; Log.line("drag start (\(mode.rawValue))") }
            view.onDone = { [weak view] rect in if let view { self.finish(rect, in: view) } }
            panel.contentView = view
            panel.orderFrontRegardless()
            return panel
        }
        NSCursor.crosshair.push()
        Log.line("dim on \(panels.count) screen(s), \(mode.rawValue), from \(fromButton ? "button" : "keys")")
    }

    private func end() {
        guard !panels.isEmpty else { return }
        Log.line("dim off (dragging=\(dragging))")
        panels.forEach { $0.orderOut(nil) }
        panels = []
        dragging = false
        fromButton = false
        NSCursor.pop()
    }

    // Esc: nothing is captured, even if the mouse is still down.
    private var cancelled = false
    private func cancel() {
        Log.line("highlight cancelled with Esc")
        cancelled = true
        end()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.cancelled = false }
    }

    // One capture per highlight: letting go of ⌃⌥ is two key events (one per key), and each used to
    // finish it, so it pasted twice.
    private var finishing = false
    private func finish(_ rect: NSRect?, in view: SelectionView) {
        if cancelled || finishing { return }
        finishing = true
        guard let rect else {
            Log.line("drag too small, cancelled")
            return end()
        }
        Log.line("drag done \(Int(rect.width))x\(Int(rect.height))")
        Paster.startedAt = .now
        if view.mode == .area {
            end()
            // Give the dim layer a moment to leave the screen so it isn't in the picture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.capture(rect) {} }
        } else {
            // Keep the drawing on screen, without the dim, so it is in the picture.
            view.inkOnly = true
            panels.filter { $0 !== view.window }.forEach { $0.orderOut(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.capture(rect) { self.end() } }
        }
    }

    // screencapture wants top-left-origin coordinates; Cocoa's origin is the main screen's bottom-left.
    // `captured` runs once the picture is taken, before it is pasted.
    private func capture(_ rect: NSRect, captured: @escaping @MainActor () -> Void) {
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY
        let region = "\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kite-\(UUID().uuidString).png")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R", region, file.path]
        let started = Date.now
        task.terminationHandler = { task in
            let status = task.terminationStatus
            Task { @MainActor in
                captured()
                defer { try? FileManager.default.removeItem(at: file) }  // nothing kept on disk
                let png = try? Data(contentsOf: file)
                Log.line("screencapture exit=\(status) bytes=\(png?.count ?? 0) in \(Int(Date.now.timeIntervalSince(started) * 1000))ms")
                guard let png else { return }
                if Enhance.isOpen { Enhance.attach(png) }  // Enhance is open: the picture goes with your ask (#253)
                else if Self.askInstead(png, under: rect) {}
                else { Paster.pasteImageIntoClaude(png) }
            }
        }
        do { try task.run() } catch {
            Log.line("screencapture failed to start: \(error)")
            captured()
        }
    }

    static func describe(_ mods: NSEvent.ModifierFlags) -> String {
        let names: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let s = names.filter { mods.contains($0.0) }.map(\.1).joined()
        return s.isEmpty ? "none" : s
    }
}

// Dims the screen and draws the box or the pen line as you drag.
// Reports the area to capture in screen coordinates, or nil to cancel.
final class SelectionView: NSView {
    static var ink: NSColor { PenStyle.color }
    static let margin: CGFloat = 160  // space kept around a drawing, so Claude sees what's near it

    let mode: Highlighter.Mode
    let hint: String
    var onStart: () -> Void = {}
    var onDone: (NSRect?) -> Void = { _ in }
    var inkOnly = false { didSet { needsDisplay = true } }
    var holdToFinish = false  // letting go of the mouse doesn't finish: letting go of the keys does

    private var start: NSPoint?
    private var current: NSPoint?
    private let path = NSBezierPath()

    init(mode: Highlighter.Mode, hint: String) {
        self.mode = mode
        self.hint = hint
        super.init(frame: .zero)
        path.lineWidth = PenStyle.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var box: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        if mode == .draw, let start { path.move(to: start) }
        onStart()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if mode == .draw, let current { path.line(to: current) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if holdToFinish { needsDisplay = true; return }  // keep going: another stroke, or a new box
        onDone(drawn)
    }

    // What would be captured now, in screen coordinates: the box, or all the strokes plus room
    // around them. Nil while it's too small to mean anything.
    var drawn: NSRect? {
        guard let window else { return nil }
        switch mode {
        case .area:
            guard let box, box.width > 4, box.height > 4 else { return nil }
            return window.convertToScreen(convert(box, to: nil))
        case .draw:
            let lines = path.isEmpty ? .zero : path.bounds
            guard lines.width > 10 || lines.height > 10 else { return nil }
            let area = lines.insetBy(dx: -Self.margin, dy: -Self.margin).intersection(bounds)
            return window.convertToScreen(convert(area, to: nil))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !inkOnly {
            NSColor.black.withAlphaComponent(0.2).setFill()
            bounds.fill()
        }
        switch mode {
        case .area:
            if let box {
                NSColor.clear.setFill()
                box.fill(using: .copy)
                NSColor.systemBlue.withAlphaComponent(0.12).setFill()
                box.fill()
                NSColor.systemBlue.setStroke()
                let outline = NSBezierPath(rect: box)
                outline.lineWidth = 2
                outline.stroke()
            }
        case .draw:
            Self.ink.setStroke()
            path.stroke()
        }
        if start == nil { drawHint() }
    }

    private func drawHint() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                     .foregroundColor: NSColor.white]
        let size = (hint as NSString).size(withAttributes: attrs)
        (hint as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 80), withAttributes: attrs)
    }
}

// The pen Highlight draws with (#272, Jason: "in just the same way as guide me, add highlighting color selection to the
// settings"): the rings' colours, pink unless you pick another (the colour it always drew in), and three widths. The
// picture pasted into Claude is the screen with the stroke on it, so it carries both.
enum PenStyle {
    static let colorKey = "highlight.penColor", widthKey = "highlight.penWidth"
    static let widths: [(key: String, label: String, width: CGFloat)] = [("thin", "Thin", 2.5), ("medium", "Medium", 4), ("thick", "Thick", 7)]
    static var color: NSColor { let k = UserDefaults.standard.string(forKey: colorKey) ?? "pink"; return RingStyle.colors.first { $0.key == k }?.color ?? .systemPink }
    static var width: CGFloat { let k = UserDefaults.standard.string(forKey: widthKey); return widths.first { $0.key == k }?.width ?? 4 }

    // A loose circle around something, as a hand draws it: for the preview in Settings and --render highlight-sample.
    static func sample(in r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let c = NSPoint(x: r.midX, y: r.midY), rx = r.width * 0.42, ry = r.height * 0.36
        for i in 0...56 {
            let t = Double(i) / 50 * 2 * .pi + 0.4
            let wobble = 1 + 0.05 * sin(t * 3)
            let pt = NSPoint(x: c.x + rx * cos(t) * wobble, y: c.y + ry * sin(t) * wobble * (t > 2 * .pi ? 0.92 : 1))
            i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
        p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round
        return p
    }
}

// The pen's preview: a word with a stroke drawn round it, in the picked colour and width.
struct PenPreview: NSViewRepresentable {
    let version: Int
    func makeNSView(context: Context) -> NSView { PenPreviewView() }
    func updateNSView(_ v: NSView, context: Context) { v.needsDisplay = true }
}
private final class PenPreviewView: NSView {
    override func draw(_ dirty: NSRect) {
        let word = "this part" as NSString  // plain words, not a button's (#277: Guide me took "Save changes" for one)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = word.size(withAttributes: attrs)
        let at = NSPoint(x: 150, y: bounds.midY - size.height / 2)
        word.draw(at: at, withAttributes: attrs)
        PenStyle.color.setStroke()
        PenStyle.sample(in: NSRect(x: at.x - 30, y: at.y - 22, width: size.width + 60, height: size.height + 44)).stroke()
    }
}

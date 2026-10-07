import AppKit
import SwiftUI

// Settings › Guide me (#271, Jason: "guide me seems VERY powerful now, can we add a section for this, like current
// screen, window in focus (besides penpal), etc, and highlighting color and shape").

// What Guide me would look at if you asked now: the app and window in focus (not Penpal; the one before it while
// Settings is in front), the screen it's on, how many controls it can read there, and the switches it needs.
// Read every two seconds while the pane shows; the controls off the main thread, as Guide me reads them.
@MainActor
final class GuideSees: ObservableObject {
    @Published var app = ""
    @Published var window = ""
    @Published var screen = ""
    @Published var controls: Int?
    @Published var trusted = false
    @Published var capture = false
    private var timer: Timer?
    private var reading = false

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        trusted = AXIsProcessTrusted()
        capture = Access.canCaptureScreen
        let front = NSWorkspace.shared.frontmostApplication
        guard let target = front == NSRunningApplication.current ? (OtherApp.last ?? OtherApp.topWindowApp()) : front, !target.isTerminated else {
            app = "None"; window = ""; screen = ""; controls = nil; return
        }
        app = target.localizedName ?? target.bundleIdentifier ?? "?"
        let ax = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
        var frame: CGRect?
        if let w = attr(ax, "AXFocusedWindow") ?? attr(ax, "AXMainWindow") {
            let win = w as! AXUIElement
            window = (attr(win, "AXTitle") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled window"
            var p = CGPoint.zero, s = CGSize.zero
            if let pv = attr(win, "AXPosition"), let sv = attr(win, "AXSize"),
               AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) { frame = CGRect(origin: p, size: s) }
        } else {
            window = trusted ? "No window" : "Can't tell without \(Permissions.controlName)"
        }
        // The screen under the window's middle (Accessibility is top-left based; screens are bottom-left).
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        let mid = frame.map { NSPoint(x: $0.midX, y: h - $0.midY) }
        let on = mid.flatMap { m in NSScreen.screens.first { $0.frame.contains(m) } } ?? NSScreen.main
        screen = on.map { "\($0.localizedName), \(Int($0.frame.width)) × \(Int($0.frame.height))" } ?? ""
        guard trusted, !reading else { if !trusted { controls = nil }; return }
        reading = true
        let pid = target.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let n = Guide.read(pid).1.count  // the read Guide me makes when you ask it (windowOnly is only the frame)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.controls = n; self.reading = false } }
        }
    }
}

struct GuideSeesView: View {
    @StateObject private var s = GuideSees()
    var body: some View {
        Section {
            LabeledContent("App in focus", value: s.app)
            LabeledContent("Window", value: s.window)
            LabeledContent("Screen", value: s.screen)
            LabeledContent {
                Text(s.controls.map { "\($0)" } ?? "—").monospaced().foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading, spacing: 1) { Text("Controls it can read"); Text("Buttons, boxes and links in that window").font(.caption).foregroundStyle(.secondary) }
            }
            row(Permissions.controlName, s.trusted, "To read the window's controls and ring them")
            row("Screen Recording", s.capture, "To send a picture of the window with your question")
        } header: {
            Text("What Guide me sees")
        } footer: {
            Text("Live, every two seconds: the app you were in before \(AppName.shown). Click into another app and come back to see it change.")
                .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { s.start() }
        .onDisappear { s.stop() }
    }
    private func row(_ name: String, _ ok: Bool, _ why: String) -> some View {
        LabeledContent {
            Text(ok ? "true" : "false").monospaced().foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 1) { Text(name); Text(why).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// The ring as Guide me draws it, around a pretend search box: colour, shape and blink as picked.
struct RingPreview: NSViewRepresentable {
    let version: Int  // a new value redraws it
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        v.subviews.forEach { $0.removeFromSuperview() }
        let field = NSTextField(labelWithString: "  Search")
        field.textColor = .secondaryLabelColor
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        field.layer?.cornerRadius = 6
        field.layer?.borderColor = NSColor.separatorColor.cgColor
        field.layer?.borderWidth = 1
        field.frame = NSRect(x: 90, y: 62, width: 220, height: 26)
        v.addSubview(field)
        let m = RingStyle.margin
        let ring = RingView(frame: field.frame.insetBy(dx: -4 - m, dy: -3 - m), inset: m, number: 1)
        v.addSubview(ring)
    }
}

// Settings › Support (#271): who makes it, where to follow along and say something, and what to send when it's broken.
struct SupportPane: View {
    @StateObject private var d = SupportState()
    static let links: [(String, String, String)] = [
        ("X", "at", "https://x.com/jasonjias"),
        ("LinkedIn", "person.crop.square", "https://www.linkedin.com/in/jasonjschen/"),
        ("Website", "globe", "https://www.santarow.com"),
        ("Feedback", "bubble.left.and.text.bubble.right", "https://www.santarow.com/feedback/?product=penpal"),
    ]
    var body: some View {
        Section {
            Text("\(AppName.shown) is made by Jason, a solo founder who just wants to build something people love. If you love \(AppName.shown), have feedback, or want to see something added, follow along and tell him.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.links, id: \.0) { name, icon, url in
                Link(destination: URL(string: url)!) {
                    LabeledContent {
                        Text(url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: ""))
                            .foregroundStyle(.secondary)
                    } label: { Label(name, systemImage: icon) }
                }
                .buttonStyle(.plain)
                .help("Opens \(url)")
            }
        }
        Section {
            LabeledContent("Version", value: Self.version)
            HStack {
                Button(d.copied ? "Copied" : "Copy diagnostics") { d.copy() }
                Spacer()
            }
        } footer: {
            Text("Diagnostics are the version, macOS and which permissions and parts are on. Never your snippets, pictures or anything you typed.")
                .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info["CFBundleVersion"] as? String ?? "?") + ")"
    }
}

@MainActor
final class SupportState: ObservableObject {
    @Published var copied = false
    static var text: String {
        func on(_ b: Bool) -> String { b ? "on" : "off" }
        var lines = ["\(AppName.shown) \(SupportPane.version)",
                     "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "\(Permissions.controlName): \(on(AXIsProcessTrusted()))",
                     "Screen Recording: \(on(Access.canCaptureScreen))",
                     "Input Monitoring: \(on(CGPreflightListenEventAccess()))"]
        let parts = Feature.allCases.filter { Flavor.current.has($0) }.map { "\($0.rawValue) \(on(Features.on($0)))" }
        lines.append("Parts: " + parts.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }
    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.copied = false }
    }
}

// A colour swatch for a menu: a filled circle as a plain image, since a picker draws SF Symbols in one ink.
@MainActor
func swatch(_ c: NSColor) -> NSImage {
    let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in c.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true }
    img.isTemplate = false
    return img
}

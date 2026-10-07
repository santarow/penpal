import AppKit
import SwiftUI
import ApplicationServices

// The two macOS permissions Workshop needs, and a way to wait for the first one.
@MainActor
enum Access {
    // Runs now if Accessibility is already allowed, else as soon as the user allows it.
    // Global key monitors added before access is granted never get events, so callers wait.
    static func whenTrusted(_ action: @escaping @MainActor () -> Void) {
        if AXIsProcessTrusted() { return action() }
        pending.append(action)
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                trustTimer?.invalidate()
                trustTimer = nil
                pending.forEach { $0() }
                pending.removeAll()
            }
        }
    }

    // Screen Recording, needed to capture a highlighted area. macOS only applies a new
    // grant after Kite restarts.
    static var canCaptureScreen: Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenCapture() { CGRequestScreenCaptureAccess() }

    // Where to turn each on, in System Settings.
    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!)
    }

    private static var pending: [@MainActor () -> Void] = []
    private static var trustTimer: Timer?
}

// What screenshots still need, kept current: checked at launch, whenever Workshop comes forward,
// and every few seconds while something's missing, so the menu and the dock say so (with a button
// to the right page of System Settings) instead of the keys silently doing nothing.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var screen = Access.canCaptureScreen
    var screenshotsReady: Bool { accessibility && screen }
    // What's missing, in a few words, or nil.
    var screenshotNeed: String? {
        !accessibility ? "Needs \(Self.controlName)" : !screen ? "Needs Screen Recording" : nil
    }
    // macOS 27 renamed the Accessibility list "Device Control and Data Access".
    nonisolated static var controlName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }
    enum Which { case accessibility, screen }
    // Set when we sent you to System Settings: a switch turned on there often only counts after
    // Workshop reopens (always for Screen Recording; for Device Control after an update), so we offer it.
    @Published private(set) var sentToSettings = false

    // macOS keeps one approval per earlier build; a stale one shows the switch on while the app isn't
    // trusted (found on Jason's Mac, 2026-09-30: three stale rows). This clears them; you run it.
    nonisolated static var resetCommand: String { "tccutil reset Accessibility \(Bundle.main.bundleIdentifier ?? "com.santarow.penpal")" }

    static func reopen() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
    private var timer: Timer?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.check() }
        }
        check()
    }

    func check() {
        let a = AXIsProcessTrusted(), s = Access.canCaptureScreen
        if a != accessibility {
            accessibility = a; Log.line("permissions: \(Self.controlName) \(a ? "on" : "off")")
            if a { Highlighter.shared.install() }  // monitors added before trust never hear anything
        }
        if s != screen { screen = s; Highlighter.shared.permissionsChanged() }
        if screenshotsReady { timer?.invalidate(); timer = nil }
        else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in MainActor.assumeIsolated { self.check() } }
        }
    }

    // The button: ask macOS (it shows its own prompt the first time), and open the right pane.
    func fix(_ which: Which? = nil) {
        if which == .accessibility || which == nil && !accessibility {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            Access.openSettings("Privacy_Accessibility"); sentToSettings = true
        } else if which == .screen || !screen {
            Access.requestScreenCapture()
            Access.openSettings("Privacy_ScreenCapture"); sentToSettings = true
        }
        check()
    }
}

// A short note near the top of the screen that goes away by itself ("Copied. Press ⌘V…").
@MainActor
enum Notice {
    private static var panel: NSPanel?
    static func show(_ text: String, seconds: Double = 3) {
        panel?.close()
        let host = NSHostingView(rootView: Text(text).font(.callout.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule()))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .statusBar; p.hasShadow = true
        p.contentView = host
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if panel === p { p.close(); panel = nil } }
    }
}

// Settings → Screenshots → "What macOS says": the live answers behind screenshots and paste, true or
// false, so a report can name the cause. Refreshed every second while it's showing.
@MainActor
final class CaptureDiagnostic: ObservableObject {
    @Published var trusted = false
    @Published var screen = false
    @Published var input = false
    private var timer: Timer?
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func refresh() {
        trusted = AXIsProcessTrusted(); screen = CGPreflightScreenCaptureAccess(); input = CGPreflightListenEventAccess()
        Permissions.shared.check()
    }
    var text: String {
        let h = Highlighter.shared
        return """
            \(AppName.shown) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            \(Permissions.controlName) (AXIsProcessTrusted): \(trusted)
            Screen Recording (CGPreflightScreenCaptureAccess): \(screen)
            Input Monitoring (CGPreflightListenEventAccess): \(input)
            Key monitor installed: \(h.monitorsInstalled)
            Last \(h.keysLabel) seen: \(h.keysSeenAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")
            """
    }
}

struct CaptureDiagnosticView: View {
    @StateObject private var d = CaptureDiagnostic()
    @ObservedObject private var h = Highlighter.shared
    var body: some View {
        // What macOS says, at the bottom of Highlight, folded (#313, Jason: "clean up the order content"): ✓ or Off, never
        // "true", and the old tccutil instruction in plain words with a button that opens the right page.
        Section {
            DisclosureGroup("Troubleshooting") {  // folded until you need it (#313)
                row(Permissions.controlName, d.trusted, "Needed for the keys and pasting into Claude")
                row("Screen Recording", d.screen, "Needed to capture")
                row("Input Monitoring", d.input, "Some Macs need it for the keys too")
                row("Key monitor", h.monitorsInstalled, "Added when \(Permissions.controlName) is on")
                LabeledContent("Last \(h.keysLabel) seen", value: h.keysSeenAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")
                HStack {
                    Button("Re-add the key monitor") { h.install() }
                    Button("Allow Input Monitoring") { _ = CGRequestListenEventAccess(); Access.openSettings("Privacy_ListenEvent") }.disabled(d.input)
                    Button("Reopen \(AppName.shown)") { Permissions.reopen() }
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(d.text, forType: .string) }
                }
                Text("Live, every second. Hold \(h.keysLabel) anywhere and “Last seen” changes. If \(Permissions.controlName) shows Off while its switch in System Settings is on, macOS is holding an old switch: in \(Permissions.controlName), select \(AppName.shown), remove it with the minus button, reopen \(AppName.shown), then turn it on again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open \(Permissions.controlName) settings…") { Access.openSettings("Privacy_Accessibility") }
            }
        }
        .onAppear { d.start() }
        .onDisappear { d.stop() }
    }
    private func row(_ name: String, _ ok: Bool, _ why: String) -> some View {
        LabeledContent {
            Text(ok ? "✓" : "Off").foregroundStyle(ok ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
        } label: {
            VStack(alignment: .leading, spacing: 1) { Text(name); Text(why).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

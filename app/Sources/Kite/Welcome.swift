import AppKit
import AVFoundation
import Speech
import SwiftUI

// First launch (#44): what the app needs from macOS, one row per permission with a ✓, in the order
// that hurts least: Accessibility first, then the microphone and speech where the app talks (not
// Penpal), Screen Recording last because macOS makes you quit and
// reopen after it. Progress lives in macOS itself, so it survives that reopen; the window comes
// back until the needed rows are done or you say later. Settings → General reopens it.
@MainActor
final class WelcomeModel: ObservableObject {
    @Published var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var speech = SFSpeechRecognizer.authorizationStatus()
    private var timer: Timer?

    func refresh() {
        Permissions.shared.check()
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
        speech = SFSpeechRecognizer.authorizationStatus()
        objectWillChange.send()
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func askMic() {
        if mic == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } } else { Access.openSettings("Privacy_Microphone") }
    }
    func askSpeech() {
        if speech == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } } else { Access.openSettings("Privacy_SpeechRecognition") }
    }
    var allNeeded: Bool { Permissions.shared.accessibility && Permissions.shared.screen }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let icon = NSApplication.shared.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 56, height: 56) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to \(AppName.shown)").font(.title2.weight(.semibold))
                    Text("A few switches in macOS, so it can see what you point at and paste into Claude for you. You press Enter; it never types for you.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            row(done: permissions.accessibility, title: Permissions.controlName,
                why: Flavor.current == .penpal ? "For the highlight keys and pasting pictures into Claude." : "For the screenshot keys, pasting into Claude, snippets and Claude Commands.",
                hint: "Already on there? After an update macOS can keep the old copy's switch: remove \(AppName.shown) with − and add it back with +, then reopen \(AppName.shown).",
                button: "Open", action: { Permissions.shared.fix(.accessibility) })
            if !permissions.accessibility && permissions.sentToSettings { ResetHint() }
            row(done: permissions.screen, title: "Screen & System Audio Recording",
                why: (Flavor.current == .penpal ? "For Highlight." : "For screenshots.") + " macOS will ask you to quit and reopen \(AppName.shown) after; this window comes back.",
                hint: "When you take a screenshot, macOS may also ask to let \(AppName.shown) “bypass the system private window picker”. Choose Allow.",
                button: "Open", action: { Permissions.shared.fix(.screen) })
            if Flavor.current.has(.chat) {
                Text("Location, Calendar and Mail are asked for only when you turn on what uses them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(model.allNeeded ? "Done" : "Later") { Welcome.finish(done: model.allNeeded) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func row(done: Bool, title: String, why: String, hint: String?, button: String,
                     action: @escaping () -> Void, optional: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : optional ? "circle.dashed" : "circle")
                .font(.title2).foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    if optional { Text("optional").font(.caption).foregroundStyle(.secondary) }
                }
                Text(why).foregroundStyle(.secondary)
                if let hint, !done { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !done {
                VStack(alignment: .trailing, spacing: 6) {
                    Button(button, action: action)
                    if Permissions.shared.sentToSettings && !optional {
                        Button("Turned on? Reopen") { Permissions.reopen() }.buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }
}

@MainActor
enum Welcome {
    private static var window: NSWindow?

    static func open() {
        let w = window ?? {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Welcome"
            w.contentView = NSHostingView(rootView: WelcomeView(model: WelcomeModel()))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            return w
        }()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    // On launch: shown until Accessibility and Screen Recording are on, or you said later this version.
    static func offer() {
        let p = Permissions.shared
        p.check()
        Log.line("permissions: \(Permissions.controlName) \(p.accessibility ? "on" : "off"), screen recording \(p.screen ? "on" : "off")")
        let later = UserDefaults.standard.string(forKey: "welcome.later") == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if !(p.accessibility && p.screen) && !later { open() }
    }

    static func finish(done: Bool) {
        if !done { UserDefaults.standard.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, forKey: "welcome.later") }
        window?.close()
    }
}

@MainActor
enum Rendering {
    // Drawn in a real (unshown) window, so lists, buttons and split views render as they do on screen.
    static func write(_ name: String, to path: String) {
        // "<window>-light" or "<window>-dark" draws it in that appearance.
        let look: NSAppearance? = name.hasSuffix("-light") ? NSAppearance(named: .aqua) : name.hasSuffix("-dark") ? NSAppearance(named: .darkAqua) : nil
        let what = name.replacingOccurrences(of: "-light", with: "").replacingOccurrences(of: "-dark", with: "")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let view: AnyView
        var size = CGSize(width: 600, height: 560)
        var wait = 2.0  // let lists and data load (bin/kite takes longer)
        var clear = false, scale: CGFloat?  // no window colour round it; more pixels than the screen's
        switch what {
        case "pin":  // the pinned dock's place, from Overlay.pinnedAnchor: top, middle, bottom, and after Claude shrinks
            let dock = CGSize(width: 222, height: 520)
            let cases: [(String, NSRect, CGFloat)] = [
                ("pinned at the top", NSRect(x: 80, y: 60, width: 900, height: 780), 0),
                ("pinned in the middle", NSRect(x: 80, y: 60, width: 900, height: 780), -160),
                ("dragged to the bottom", NSRect(x: 80, y: 60, width: 900, height: 780), -700),
                ("middle, then Claude resized", NSRect(x: 200, y: 260, width: 760, height: 560), -160)]
            view = AnyView(HStack(spacing: 14) { ForEach(cases.indices, id: \.self) { i in
                let (label, claude, off) = cases[i]
                let a = Overlay.pinnedAnchor(claude: claude, offset: NSPoint(x: Overlay.tabSize.width + 6, y: off), panel: dock, room: true)
                VStack(spacing: 6) {
                    Canvas { ctx, size in
                        let k = size.width / 1440, H: CGFloat = 900
                        func r(_ n: NSRect) -> CGRect { CGRect(x: n.minX * k, y: (H - n.maxY) * k, width: n.width * k, height: n.height * k) }
                        ctx.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary))
                        ctx.fill(Path(roundedRect: r(claude), cornerRadius: 6), with: .color(.gray.opacity(0.45)))
                        ctx.fill(Path(roundedRect: r(NSRect(x: a.x - dock.width, y: a.y - dock.height, width: dock.width, height: dock.height)), cornerRadius: 6), with: .color(.blue.opacity(0.85)))
                    }
                    .frame(width: 288, height: 180)
                    Text(label).font(.caption)
                }
            } }.padding(16))
            size = CGSize(width: 1260, height: 240)
        case "dock": AgentStore.shared.refresh(); view = Overlay.picture(); size = CGSize(width: 260, height: 900)
        case "dock-site":  // the website's dock picture (#284): the dock alone at its own size, clear round it, 4x for a 2x page
            AgentStore.shared.refresh(); view = Overlay.picture(); size = NSHostingView(rootView: view).fittingSize; clear = true; scale = 4
        case "history": let m = HistoryModel(); m.load(); view = AnyView(HistoryView(model: m)); size = CGSize(width: 1080, height: 680); wait = 6
        case let w where w.hasPrefix("settings-") && SettingsPane(rawValue: String(w.dropFirst(9))) != nil:  // any pane by its name (#271)
            SettingsNav.shared.pane = SettingsPane(rawValue: String(w.dropFirst(9)))
            view = AnyView(SettingsView(expander: Expander(lenses: .locate(), live: false), overlay: Overlay(lenses: .locate(), live: false), highlighter: .shared))
            size = CGSize(width: 900, height: 760); wait = 3
        case "settings-snippets":  // Settings › Snippets, with Your Claude talks (#270)
            SettingsNav.shared.pane = .lenses
            view = AnyView(SettingsView(expander: Expander(lenses: .locate(), live: false), overlay: Overlay(lenses: .locate(), live: false), highlighter: .shared))
            size = CGSize(width: 900, height: 700)
        case "settings-general":  // Settings › General, with the Floating icon switch (#262)
            SettingsNav.shared.pane = .general
            view = AnyView(SettingsView(expander: Expander(lenses: .locate(), live: false), overlay: Overlay(lenses: .locate(), live: false), highlighter: .shared))
            size = CGSize(width: 900, height: 700)
        case "settings-screenshots":  // Settings › Screenshots; -screenshots.lines 0 shows another pick without saving it
            SettingsNav.shared.pane = .screenshots
            view = AnyView(SettingsView(expander: Expander(lenses: .locate(), live: false), overlay: Overlay(lenses: .locate(), live: false), highlighter: .shared))
            size = CGSize(width: 900, height: 700)
        case "commands": let m = CommandsModel(); m.load(); view = AnyView(CommandsView(model: m)); size = CGSize(width: 760, height: 620); wait = 4
        case "dock-icon":  // the collapsed dock beside the macOS Dock's own icon for this app, at the Dock's size
            let sz = DockTile.size
            let dock = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            func cell(_ v: some View, _ label: String) -> some View {
                VStack(spacing: 8) { v.frame(width: sz + 12, height: sz + 12); Text(label).font(.caption).multilineTextAlignment(.center).frame(width: 120) }
            }
            view = AnyView(HStack(alignment: .top, spacing: 18) {
                cell(Image(nsImage: dock).resizable().frame(width: sz, height: sz), "macOS Dock icon\n\(Int(sz)) pt")
                cell(DockIcon(size: sz), "floating, collapsed\n\(Int(sz)) pt")
            }.padding(24).background(LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.4), Color(red: 0.4, green: 0.35, blue: 0.3)], startPoint: .top, endPoint: .bottom)))
            size = CGSize(width: 640, height: 190)
        case "highlight-sample":  // a Highlight picture as it goes into Claude: a stroke round something, in the pen's colour and width (#272)
            let img = NSImage(size: NSSize(width: 420, height: 160), flipped: false) { r in
                NSColor.white.setFill(); r.fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black]
                ("Your changes aren't saved yet." as NSString).draw(at: NSPoint(x: 24, y: 112), withAttributes: attrs)
                let button = NSRect(x: 150, y: 52, width: 120, height: 30)
                NSColor.darkGray.setFill(); NSBezierPath(roundedRect: button, xRadius: 7, yRadius: 7).fill()  // grey, so any pen colour shows
                ("Save changes" as NSString).draw(at: NSPoint(x: 163, y: 58), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white])
                PenStyle.color.setStroke()
                PenStyle.sample(in: button.insetBy(dx: -34, dy: -24)).stroke()
                return true
            }
            view = AnyView(Image(nsImage: img)); size = CGSize(width: 420, height: 160)
        case "menubar-icon":  // the menu bar icon (#268): at 18 pt on a light, a dark and a tinted bar, and large to inspect
            func bar(_ c: Color, _ tint: Color) -> some View {
                HStack(spacing: 14) {
                    Image(nsImage: PenpalMark.menuBar).renderingMode(.template).foregroundStyle(tint)
                    Text("Mon Oct 5  9:40 PM").font(.system(size: 13)).foregroundStyle(tint)
                }
                .padding(.horizontal, 12).frame(height: 24).background(c)
            }
            view = AnyView(HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    bar(Color(white: 0.93), .black); bar(Color(white: 0.16), .white); bar(Color(red: 0.32, green: 0.4, blue: 0.56), .white)
                }
                Image(nsImage: PenpalMark.image(size: 144)).renderingMode(.template).foregroundStyle(.black)
                    .padding(8).background(Color.white).border(Color.gray.opacity(0.3))
            }.padding(20).background(Color(white: 0.85)))
            size = CGSize(width: 520, height: 200)
        case "screenshots": view = AnyView(Form { CaptureDiagnosticView() }.formStyle(.grouped)); size = CGSize(width: 680, height: 420)
        default: view = AnyView(WelcomeView(model: WelcomeModel()))
        }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(clear ? Color.clear : Color(nsColor: .windowBackgroundColor)))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: clear ? [.borderless] : [.titled], backing: .buffered, defer: false)
        if clear { w.isOpaque = false; w.backgroundColor = .clear }
        if let look { w.appearance = look; host.appearance = look }
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        host.layoutSubtreeIfNeeded()
        let scaled = scale.flatMap { k in NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * k), pixelsHigh: Int(host.bounds.height * k),
                                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) }
        scaled?.size = host.bounds.size  // the same points, k pixels each
        guard let rep = scaled ?? host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// Shown when Device Control still isn't on after a trip to System Settings: usually macOS holding an
// old build's switch. The command is copied for you to run in Terminal (it changes a privacy setting).
struct ResetHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Switch on, but still not working? macOS is holding an old switch from an earlier \(AppName.shown). Reset it in Terminal, then reopen and turn \(AppName.shown) on again:")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(Permissions.resetCommand).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Permissions.resetCommand, forType: .string) }
                Button("Reopen \(AppName.shown)") { Permissions.reopen() }
            }
        }
        .padding(.leading, 36)
    }
}

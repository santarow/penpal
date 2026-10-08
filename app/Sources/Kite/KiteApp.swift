import SwiftUI

// A click on the app's icon in the macOS Dock opens or closes the dock, like a click on its floating icon (#255).
@MainActor
final class KiteAppDelegate: NSObject, NSApplicationDelegate {
    // SwiftUI adds a View menu with nothing in it; Penpal's menus are Penpal, Edit, Highlight, Snippets, Magic, Window
    // and Help (#268). Taken out at launch and whenever the app comes in front (SwiftUI may build the bar again).
    func applicationDidFinishLaunching(_ note: Notification) {
        Self.dropEmptyMenus()
        SnippetMenuStyle.start()
        OtherApp.start()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.dropEmptyMenus() }
        }
    }
    static func dropEmptyMenus() {
        guard let main = NSApp.mainMenu else { return }
        for item in main.items where item.title == "View" && (item.submenu?.items.allSatisfy { $0.isHidden || $0.isSeparatorItem } ?? true) {
            main.removeItem(item)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Overlay.current?.toggle()
        return false  // nothing else: no new window
    }
}

// The shell: a menu bar item. The dock, Settings and agent windows are opened from there.
@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        KiteApp.main()
    }
}

struct KiteApp: App {
    static var menuBarMark: NSImage { PenpalMark.menuBar }
    @NSApplicationDelegateAdaptor(KiteAppDelegate.self) private var appDelegate
    @StateObject private var expander = Expander(lenses: .locate())
    @StateObject private var overlay = Overlay(lenses: .locate())
    @StateObject private var highlighter = Highlighter.shared
    @StateObject private var voiceAgent = VoiceAgent.shared

    // Rule: no feature starts in init(). Each one is a StateObject, created after AppKit has
    // launched. Creating the voice agent here once installed its key monitors too early and
    // silently blocked every mouse click to Kite's windows (found by bisecting, 2026-09-24).
    init() {
        Kite.moveHome()  // Penpal: its data from ~/.kite into its own folder, once, before anything reads it (#310)
        // --render <welcome|holly> <out.png>: draw that window to a picture and quit, before any
        // feature starts (for checking a screen while another copy of the app is in use).
        if CommandLine.arguments.contains("--picture-labels") {  // three labels in a row, as pasted, then quit
            MainActor.assumeIsolated { for _ in 0..<3 { print(Paster.pictureLabel().debugDescription) } }
            exit(0)
        }
        if CommandLine.arguments.contains("--snippets-check") {  // first load, a delete that stays, then Restore (#261); run with a spare home
            MainActor.assumeIsolated {
                let store = LensStore.locate()
                func show(_ step: String) {
                    print(step + ":", store.sets().map { "\($0)\(store.isOn($0) ? "" : " (off)") [\(store.lenses(in: $0).map(\.name).joined(separator: " "))]" }.joined(separator: "  "))
                }
                store.seedDefaults(); show("first load")
                if let f = store.lenses(in: LensStore.mySet).first(where: { $0.name == "formal" }) { store.delete(f) }
                try? "# plain\n\nmine\n".write(to: LensStore.userRoot.appendingPathComponent("plain.md"), atomically: true, encoding: .utf8)
                store.seedDefaults(); show("formal deleted, plain edited, next launch")
                print("restore: changed", store.restoreDefaults(replace: false)); show("after restore")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--lens-check") {  // save and expand two test lenses through the real code, then quit
            MainActor.assumeIsolated {
                let store = LensStore.locate()
                for (name, body) in [("zzspace", "🏞️ {n} "), ("zzlines", "first line\n  indented second\n\nafter a blank ")] {
                    if let lens = store.save(name: name, summary: "test", body: body, set: LensStore.mySet) {
                        print(name, "→", (store.expansion(name) ?? "nil").debugDescription)
                        try? FileManager.default.trashItem(at: lens.url, resultingItemURL: nil)
                    }
                }
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-status"), i + 2 < CommandLine.arguments.count {  // a session's Live status note, drawn
            let a = CommandLine.arguments
            setvbuf(stdout, nil, _IOLBF, 0)
            MainActor.assumeIsolated { StatusWindows.render(transcript: a[i + 1], to: a[i + 2]) }
            exit(0)
        }
        if CommandLine.arguments.contains("--time-agents") {  // Enhance timed before and after #254
            setvbuf(stdout, nil, _IOLBF, 0)
            MainActor.assumeIsolated { timeAgents() }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--time-guide"), i + 2 < CommandLine.arguments.count {  // Guide me timed, nothing drawn
            let a = CommandLine.arguments
            setvbuf(stdout, nil, _IOLBF, 0)
            MainActor.assumeIsolated { Guide.time(bundle: a[i + 1], goal: a[i + 2]) }
            exit(0)
        }
        if CommandLine.arguments.contains("--time-dock") {  // the dock's open and fold, timed offscreen
            setvbuf(stdout, nil, _IOLBF, 0)
            MainActor.assumeIsolated { timeDock() }
            exit(0)
        }
        if CommandLine.arguments.contains("--send-sim") {  // Send against a pretend Claude, slow or turning pictures down
            setvbuf(stdout, nil, _IOLBF, 0)
            exit(MainActor.assumeIsolated { sendSim() } ? 0 : 1)
        }
        if CommandLine.arguments.contains("--send-check") {  // what Enhance's Send would paste, without pasting
            setvbuf(stdout, nil, _IOLBF, 0)
            MainActor.assumeIsolated { sendCheck() }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-enhance"), i + 2 < CommandLine.arguments.count {  // Enhance before and after, drawn
            let a = CommandLine.arguments
            setvbuf(stdout, nil, _IOLBF, 0)
            let n = i + 3 < a.count ? Int(a[i + 3]) ?? 1 : 1  // how many stand-in pictures; a 4th word "norun" skips the real run
            MainActor.assumeIsolated { renderEnhance(ask: a[i + 1], out: a[i + 2], pictures: n, run: !a.contains("norun")) }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--guide-sim"), i + 1 < CommandLine.arguments.count {  // what crosses off what, simulated
            let out = CommandLine.arguments[i + 1]
            setvbuf(stdout, nil, _IOLBF, 0)
            exit(MainActor.assumeIsolated { Guide.simulate(out: out) } ? 0 : 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--guide-shot"), i + 3 < CommandLine.arguments.count {  // Guide me on a real app, for the website (#277)
            let a = CommandLine.arguments
            setvbuf(stdout, nil, _IOLBF, 0)
            MainActor.assumeIsolated { Guide.siteShot(bundle: a[i + 1], goal: a[i + 2], out: a[i + 3], dark: a.contains("--dark")) }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--guide-check"), i + 3 < CommandLine.arguments.count {  // Guide me on that app, drawn to a picture
            let a = CommandLine.arguments
            setvbuf(stdout, nil, _IOLBF, 0)
            MainActor.assumeIsolated { Guide.check(bundle: a[i + 1], goal: a[i + 2], out: a[i + 3]) }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 2 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Rendering.write(CommandLine.arguments[i + 1], to: CommandLine.arguments[i + 2]) }
            exit(0)
        }
        Guide.watchApps(); _ = Self.launchFlags
        LensStore.locate().seedDefaults()  // first load: the default snippets into yours (#261)
    }
    // Launch flags for a look at a window without clicking (tests): --fleet [outline|board|org|radial|table], --mission <name>|shelf
    private static let launchFlags: Void = {
        let args = CommandLine.arguments
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Setup.check() }  // release builds: what this Mac is missing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MoveToApplications.check(); OtherBuild.check(); _ = Permissions.shared }  // from the DMG? the other build running too?
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Welcome.offer() }  // permissions first
        if let i = args.firstIndex(of: "--guide-colors"), i + 1 < args.count {  // #309: info rings blue, action rings red
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { Guide.colorsRender(out: out) } }
        }
        if let i = args.firstIndex(of: "--guide-308-check"), i + 1 < args.count {  // #308: merge, app switch, outcomes, tour, drag
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { Guide.check308(out: out) } }
        }
        if let i = args.firstIndex(of: "--guide-fold-check"), i + 1 < args.count {  // a canned answer folded into the steps (#306)
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { Guide.foldCheck(out: out) } }
        }
        if args.contains("--paste-target-check") {  // where a paste into Claude would go now, read-only (#319)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { Paster.targetCheck() } }
        }
        if args.contains("--guide-read-check") {  // what a look reads, counted per window (#263)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { Guide.readCheck() } }
        }
        if let i = args.firstIndex(of: "--guide-dns-check"), i + 1 < args.count {  // the domain demo's two looks, read-only (#263)
            let out = args[i + 1]
            DispatchQueue.global().async { DispatchQueue.main.async { MainActor.assumeIsolated { Guide.dnsCheck(out: out) } } }
        }
        if let i = args.firstIndex(of: "--guide-ask-check"), i + 5 < args.count {  // a question folded into Guide me's steps (#306)
            let a = args
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { Guide.askCheck(bundle: a[i + 1], goal: a[i + 2], question: a[i + 3], out: a[i + 4], done: Int(a[i + 5]) ?? 0) } }
        }
        if args.contains("--pill-check") {  // the folded Enhance pill: drags, a click, its own place (#297); then quit
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { Enhance.pillCheck() } }
        }
        if args.contains("--order-check") {  // which of Penpal's is on top after each touch (#283); then quit
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if let o = Overlay.current { o.orderCheck() } else { print("FAIL no overlay"); exit(1) } }  // exits itself
        }
        if args.contains("--float-check") {  // the floating icon and the dock, on the live panels; then quit (#262)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Overlay.current?.floatCheck(); exit(0) }
        }
        if let i = args.firstIndex(of: "--menu-render"), i + 1 < args.count {  // the top bar's Snippets menu as styled, light and dark, to a PNG (#268)
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated { SnippetMenuStyle.render(to: out); exit(0) } }
        }
        if args.contains("--snippets-menu-check") {  // #270: after a snippet edit, the rebuilt Snippets menu reads back styled, never opened
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MainActor.assumeIsolated {
                var failed = 0
                @MainActor func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
                // As AppKit does right before it shows a menu: the menu's delegate (SwiftUI's) brings it up to date. No
                // tracking: what it reads is what would be drawn first.
                @MainActor func items() -> [NSMenuItem] {
                    guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Snippets" })?.submenu else { return [] }
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.delegate?.menuWillOpen?(menu)
                    let all = menu.items.filter { $0.title.contains("\t") }
                    menu.delegate?.menuDidClose?(menu)
                    return all
                }
                @MainActor func check(_ what: String) {
                    let all = items(), raw = all.filter { !SnippetMenuStyle.isStyled($0) }
                    print((raw.isEmpty && !all.isEmpty ? "PASS " : "FAIL ") + what + ": \(all.count - raw.count) of \(all.count) styled"
                          + (raw.isEmpty ? "" : " (raw: " + raw.prefix(3).map { $0.title.debugDescription }.joined(separator: ", ") + ")"))
                    if !raw.isEmpty || all.isEmpty { failed += 1 }
                }
                let store = LensStore.locate()
                check("at launch")
                let lens = store.save(name: "zzcheck", summary: "a check, trashed after", body: "check", set: LensStore.mySet)
                Expander.current?.objectWillChange.send(); spin()
                let added = items().contains { $0.title.hasPrefix("zzcheck") }
                print((added ? "PASS " : "FAIL ") + "a snippet added: the menu rebuilt with it"); if !added { failed += 1 }
                check("rebuilt after the edit")
                if let lens { try? FileManager.default.trashItem(at: lens.url, resultingItemURL: nil) }
                Expander.current?.objectWillChange.send(); spin()
                let gone = !items().contains { $0.title.hasPrefix("zzcheck") }
                print((gone ? "PASS " : "FAIL ") + "the check snippet is gone again"); if !gone { failed += 1 }
                check("rebuilt after it's gone")
                let others = NSApp.mainMenu?.items.first { $0.title == "Snippets" }?.submenu?.items.filter { !$0.title.contains("\t") && !$0.isSeparatorItem }.map(\.title) ?? []
                print((others == ["Edit snippets…"] ? "PASS " : "FAIL ") + "the menu is the snippets and Edit snippets… only: \(others)"); if others != ["Edit snippets…"] { failed += 1 }
                print(failed == 0 ? "all passed" : "\(failed) failed")
                exit(0)
            } }
        }
        if args.contains("--guide-open") {  // Guide me's goal box, as from the dock (#307: to see its ready claude's model)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Guide.start() }
        }
        if args.contains("--guide-sees") {  // what Settings › Guide me shows, read live, then quit (#271)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated {
                let s = GuideSees(); s.start()
                RunLoop.main.run(until: Date().addingTimeInterval(4))
                print("app: \(s.app) | window: \(s.window) | screen: \(s.screen) | controls: \(s.controls.map(String.init) ?? "-") | AX \(s.trusted) | capture \(s.capture)")
                let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Overlay.claudeBundle).first?.processIdentifier ?? 0
                print("Claude: Guide.read all: \(Guide.read(pid).1.count), window only: \(Guide.read(pid, windowOnly: true).1.count)")
                exit(0)
            } }
        }
        if args.contains("--menu-dump") {  // the top menu bar SwiftUI built, item by item, then quit (#268)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                func dump(_ menu: NSMenu, _ depth: Int) {
                    for item in menu.items {
                        let pad = String(repeating: "    ", count: depth)
                        if item.isSeparatorItem { print(pad + "────"); continue }
                        if item.isHidden { continue }
                        let key = item.keyEquivalent.isEmpty ? "" : "  ⌘" + item.keyEquivalent.uppercased()
                        let styled = item.attributedTitle.map { a in a.length > 0 && a.attribute(.paragraphStyle, at: 0, effectiveRange: nil) != nil } ?? false
                        print(pad + (item.state == .on ? "✓ " : "") + item.title.replacingOccurrences(of: "\t", with: "  ⇥ ") + key
                              + (item.isEnabled ? "" : "  (dimmed)") + (styled ? "  [styled]" : ""))
                        if let sub = item.submenu, depth < 3 { dump(sub, depth + 1) }
                    }
                }
                if let main = NSApp.mainMenu { SnippetMenuStyle.style(main); dump(main, 0) }
                exit(0)
            }
        }
        if args.contains("--dock-open") {  // the dock opens at launch (for a look at it)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if let o = Overlay.current, !o.expanded { o.toggle() } }
        }
        if args.contains("--enhance") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Enhance.open() } }  // for a look (#273)
        if args.contains("--commands") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { CommandsWindow.toggle() } }
        if args.contains("--usage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { UsageWindow.toggle() }
        }
        if args.contains("--history") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { HistoryWindow.toggle() }
        }
        if let i = args.firstIndex(of: "--settings"), i + 1 < args.count { SettingsNav.first = SettingsPane(rawValue: args[i + 1]) }
        if args.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SettingsWindow.open() }
        }
        if args.contains("--lenses") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { LensWindow.open(.locate()) }
        }
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(expander: expander, overlay: overlay, highlighter: highlighter)
        } label: {
            Image(nsImage: Self.menuBarMark).accessibilityLabel(AppName.shown)
        }
        .commands {  // Penpal's own menus while it's in front (#268, Jason: "is there a way to have the menu settings appear
            // when its in focus?"): the same items as the menu bar icon's menu, in the top menu bar.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.open() }.keyboardShortcut(",")
            }
            CommandMenu("Highlight") { HighlightMenu(highlighter: highlighter, inBar: true) }
            CommandMenu("Snippets") { SnippetsMenu(expander: expander) }
            if Features.on(.guide) || Enhance.available { CommandMenu("Magic") { MagicItems(highlighter: highlighter, highlight: false) } }
            CommandGroup(after: .appInfo) {  // History and Usage in the app's own menu (#292), where you'd look first
                Divider()
                WindowItems()
            }
            CommandGroup(before: .windowList) {
                IconItems(overlay: overlay)
                Divider()
            }
            CommandGroup(replacing: .help) { Button("Send Feedback…") { Feedback.compose() } }
        }
    }
}

// The menu bar icon's menu (#268, Jason: "what can we clean up here?"): what you do first, then two submenus,
// the windows, and the app. The top menu bar shows the same items while Penpal is in front.
struct MenuContent: View {
    @ObservedObject var expander: Expander
    @ObservedObject var overlay: Overlay
    @ObservedObject var highlighter: Highlighter

    var body: some View {
        MagicItems(highlighter: highlighter, highlight: Features.on(.capture))
        Divider()
        if Features.on(.lenses) { Menu("Snippets") { SnippetsMenu(expander: expander) } }
        if Features.on(.capture) { Menu("Highlight options") { HighlightMenu(highlighter: highlighter, inBar: false) } }
        Divider()
        WindowItems()
        Divider()
        IconItems(overlay: overlay)
        Button("Settings…") { SettingsWindow.open() }.keyboardShortcut(",")
        Button("Send Feedback…") { Feedback.compose() }
        Button("Quit \(AppName.shown)") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

// Highlight, Guide me and Enhance: the dock's main tiles, as menu items.
struct MagicItems: View {
    @ObservedObject var highlighter: Highlighter
    let highlight: Bool
    var body: some View {
        if highlight { Button("Highlight  \(highlighter.keysLabel)") { highlighter.startFromButton() } }
        if Features.on(.guide) { Button("Guide me…") { Guide.start() } }
        if Enhance.available { Button("Enhance…") { Enhance.open() } }
    }
}

// Snippets: each one pastes into Claude, then the editor (#270: the ;name switch and how your Claude talks are in
// Settings › Snippets).
struct SnippetsMenu: View {
    @ObservedObject var expander: Expander
    var body: some View {
        let lenses = expander.lenses
        ForEach(lenses.names(), id: \.self) { name in
            // Its name, its description in grey, what you type for it in the shortcut column (SnippetMenuStyle).
            Button(SnippetMenuStyle.title(name: name, summary: lenses.summary(name), trigger: lenses.abbreviation(name))) {
                if let text = lenses.expansion(name) { Paster.pasteIntoClaude(text) }
            }
        }
        Divider()
        Button("Edit snippets…") { LensWindow.open(lenses) }
    }
}

// Highlight's switches: the keys on or off, the way it picks, picture numbering. In the top menu bar its menu also
// starts one.
struct HighlightMenu: View {
    @ObservedObject var highlighter: Highlighter
    let inBar: Bool
    var body: some View {
        if inBar, highlighter.canCapture { Button("Highlight") { highlighter.startFromButton() }; Divider() }
        if highlighter.canCapture {
            Toggle("Highlight with \(highlighter.keysLabel)", isOn: $highlighter.enabled)
            Picker("How it picks", selection: $highlighter.mode) {
                ForEach(Highlighter.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } else {
            Button("Highlight needs Screen Recording: allow…") { highlighter.requestCapture() }
        }
        if Paster.numberPictures {
            Button("Reset picture numbering (\u{1F5BC} 1 next)") { Paster.resetPictures() }
        }
        if !Permissions.shared.accessibility {
            Button("Highlight and paste need \(Permissions.controlName): allow…") { Permissions.shared.fix(.accessibility) }
        }
        if !Permissions.shared.accessibility || !Permissions.shared.screen {
            Button("Permissions…") { Welcome.open() }
        }
    }
}

// The windows: History and Usage first (#292, Jason: "wheres the metrics and session history? perhaps add it to the menu
// bar?"), then Claude Commands (and what else this app has). Usage opens whether or not its meter runs: the meter is
// the /usage reading every 15 minutes (Settings › Dock › Windows); the window reads it only while it's open.
struct WindowItems: View {
    var body: some View {
        if Features.on(.history) { Button("History…") { HistoryWindow.toggle() }.keyboardShortcut("y") }
        if Features.allowed(.usage) { Button("Usage…") { UsageWindow.toggle() } }
        if Features.on(.commands) { Button("Claude Commands…") { CommandsWindow.toggle() } }
    }
}

// The floating icon's switch (#262); with it off, the dock is opened from here.
struct IconItems: View {
    @ObservedObject var overlay: Overlay
    var body: some View {
        Toggle("Floating icon", isOn: $overlay.iconOn)
        if !overlay.iconOn { Toggle("Show the dock", isOn: $overlay.dockOpen) }
    }
}

// Send Feedback…: a draft email with the versions filled in, in your mail app. You send it.
enum Feedback {
    static let address = Flavor.feedbackAddress  // where feedback goes (Flavor.swift)
    // Penpal's feedback is a page on santarow.com (santarow #170), opened in the browser instead of a draft email.
    static let page = URL(string: "https://www.santarow.com/feedback/?product=penpal")!
    static func compose() {
        if Flavor.current == .penpal { NSWorkspace.shared.open(page); return }
        let info = Bundle.main.infoDictionary ?? [:]
        let kite = (info["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info["CFBundleVersion"] as? String ?? "?") + ")"
        let body = "\n\n\n---\n\(AppName.shown) \(kite)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [URLQueryItem(name: "subject", value: "\(AppName.shown) feedback"), URLQueryItem(name: "body", value: body)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}

// The panes of Settings, in the sidebar's order. Chief of staff shows only while its Labs switch is on.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, features, screenshots, lenses, magic, guide, enhance, dock, voice, models, toolbox, telegram, tracking, location, chief, support
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .guide: "Guide me"
        case .enhance: "Enhance"
        case .magic: "Magic"  // #307: the models Guide me and Enhance use
        case .support: "Support"
        case .features: "Features"
        case .dock: "Dock"
        case .lenses: "Snippets"  // #257: "Lenses" was ours; saved text you drop in is a snippet
        case .screenshots: "Highlight"  // #268: what ⌃⌥ does is Highlight, everywhere
        case .voice: "Voice"
        case .models: "Models"
        case .toolbox: "Toolbox"
        case .telegram: "Assistant"
        case .tracking: "Packages"
        case .location: "Location"
        case .chief: "Chief of Staff"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .guide: "hand.point.up.left.fill"
        case .enhance: "wand.and.stars"  // the dock's Enhance tile
        case .magic: "sparkles"
        case .support: "heart.fill"
        case .features: "switch.2"
        case .dock: "square.grid.2x2.fill"
        case .lenses: "text.quote"
        case .screenshots: "pencil.tip.crop.circle"  // the dock's Highlight tile
        case .voice: "waveform"
        case .models: "cpu.fill"
        case .toolbox: "wrench.and.screwdriver.fill"
        case .telegram: "paperplane.fill"
        case .tracking: "shippingbox.fill"
        case .location: "location.fill"
        case .chief: "briefcase.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: .gray
        case .guide: .pink
        case .enhance: .purple
        case .magic: .indigo
        case .support: .red
        case .features: .blue
        case .dock: .indigo
        case .lenses: Palette.snippets
        case .screenshots: .blue  // the dock's Highlight tile (#272: one colour per part, as on the dock)
        case .voice: .pink
        case .models: .purple
        case .toolbox: .gray
        case .telegram: .cyan
        case .tracking: .green
        case .location: .blue
        case .chief: .gray
        }
    }
    @MainActor static var visible: [SettingsPane] { allCases.filter { ($0 != .chief || Labs.chief) && $0.inThisApp } }
    // The sidebar's groups, spaced apart as System Settings' are (#272): General; the parts (Highlight, Snippets, Dock,
    // Guide me); Support. Other apps keep one list.
    @MainActor static var groups: [(header: String?, panes: [SettingsPane])] {
        let shown = Set(visible)
        let layout: [(String?, [SettingsPane])] = Flavor.current == .penpal
            ? [(nil, [.general]), (nil, [.screenshots, .lenses, .dock, .magic, .guide]), (nil, [.support])]  // Magic above Guide me; its Enhance part was the Enhance pane (#307)  // no Magic group (#273, with Enhance gone)
            : [(nil, visible)]
        return layout.map { ($0.0, $0.1.filter { shown.contains($0) }) }.filter { !$0.1.isEmpty }
    }
    // Each SantaRow app shows its own panes (#209).
    var inThisApp: Bool {
        // No Features pane in Penpal (#271, Jason: "maybe we shouldnt even have features"): each part's switch is in its own pane.
        let penpal: [SettingsPane] = [.general, .screenshots, .lenses, .dock, .magic, .guide, .support]
        return penpal.contains(self)
    }
}
@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    nonisolated(unsafe) static var first: SettingsPane?  // --settings <pane>, for a look without clicking
    @Published var pane: SettingsPane? = SettingsNav.first ?? .general
    @Published var search = ""  // the sidebar's search field: panes whose name has it
}

// Settings is a plain window, like the agent windows, so the dock's gear can open and close it.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func open(pane: SettingsPane) {
        SettingsNav.shared.pane = pane
        open()
    }

    static func open() {
        guard let expander = Expander.current, let overlay = Overlay.current else { return }
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "\(AppName.shown) Settings"
            let host = NSHostingView(rootView: SettingsView(expander: expander, overlay: overlay, highlighter: .shared))
            host.sizingOptions = [.minSize]  // keep the window's own size; the form scrolls
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            return w
        }()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    // A second click closes it, if it's the window in front.
    static func toggle() {
        if let w = window, w.isVisible, w.isKeyWindow, NSApp.isActive { w.performClose(nil) } else { open() }
    }
}

// A Labs switch as a binding, with the view refreshed when it flips.
private final class LabsState: ObservableObject { @Published var version = 0 }

struct SettingsView: View {
    @StateObject private var labsState = LabsState()
    private func labs(_ key: String) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: key) },
                set: { UserDefaults.standard.set($0, forKey: key); labsState.version += 1
                       AgentStore.shared.refresh(); Overlay.current?.objectWillChange.send() })
    }
    @ObservedObject var expander: Expander
    @ObservedObject var overlay: Overlay
    @ObservedObject var highlighter: Highlighter
    @AppStorage(Paster.targetKey) private var target = Paster.Target.claude
    @AppStorage(Paster.linesKey) private var pictureLines = Paster.linesDefault
    @AppStorage(Paster.numberKey) private var numberPictures = true  // so the lines picker follows the switch
    @ObservedObject private var access = MacAccess.shared
    @AppStorage("holly.name") private var hollyName = ""   // the name in labels and the sidebar, redrawn on a change
    @ObservedObject private var features = Features.shared
    @ObservedObject private var appearance = Appearance.shared

    // Like System Settings: panes in a sidebar, each one a short grouped form.
    @ObservedObject private var nav = SettingsNav.shared
    @FocusState private var sidebarFocused: Bool
    var body: some View {
        NavigationSplitView {
            // As System Settings' sidebar (#272, Jason: "anyway we can just copy this?"): the system's sidebar list, so its
            // font, row height, selection and group spacing are macOS's own; 20-point tiles, 7 points from the label.
            List(selection: $nav.pane) {
                ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { _, g in
                    let rows = g.panes.filter { nav.search.isEmpty || $0.title.localizedCaseInsensitiveContains(nav.search) }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { p in
                                HStack(spacing: 7) {
                                    IconTile(symbol: p.icon, color: p.color, size: 20)
                                    // 13 points in the label colour, as System Settings' (the sidebar's own grey read lighter,
                                    // #272: "perhaps make the font weight heavier?"); the selected one bold, white on the blue.
                                    Text(p.title).font(.body.weight(nav.pane == p ? .bold : .regular))
                                        .foregroundStyle(nav.pane == p ? AnyShapeStyle(.primary) : AnyShapeStyle(Color(nsColor: .labelColor)))  // .primary turns white on the blue selection only
                                }
                                .tag(p)
                            }
                        } header: {
                            if let h = g.header { Text(h) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .focused($sidebarFocused)  // the sidebar has focus when Settings opens, so its selection is the solid accent pill
            .onAppear { sidebarFocused = true }
            .environment(\.sidebarRowSize, .large)  // System Settings' 32-point rows
            .searchable(text: $nav.search, placement: .sidebar)
            .frame(minWidth: 232, idealWidth: 232)
            .navigationSplitViewColumnWidth(min: 232, ideal: 232, max: 232)  // its sidebar's width; on its own it stayed at 145
            .toolbar(removing: .sidebarToggle)  // System Settings' sidebar doesn't fold away
        } detail: {
            Form {
                switch nav.pane ?? .general {
                case .general: generalPane
                case .features: EmptyView()
                case .dock: dockPane
                case .lenses: lensesPane
                case .screenshots: screenshotsPane
                case .voice, .models, .toolbox, .telegram, .tracking, .location, .chief: EmptyView()
                case .guide: guidePane
                case .enhance: enhancePane
                case .magic: magicPane
                case .support: SupportPane()
                }
            }
            .formStyle(.grouped)  // scrolls when taller than the window
            .navigationTitle((nav.pane ?? .general).title)
        }
        .onAppear { access.refresh() }
        .frame(minWidth: 680, minHeight: 440)
    }

    @ViewBuilder private var generalPane: some View {
        Section {
            Toggle("Floating icon", isOn: $overlay.iconOn)
        } footer: {
            Text("\(AppName.shown)'s icon floats above your other apps. Click it to open or close the dock; drag it anywhere. Off: the icon in the macOS Dock and the menu bar open the dock.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        Section("Appearance") {
            Picker("Theme", selection: $appearance.mode) {
                ForEach(Appearance.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        // Agents' fuel, schedule times and roster notes (#312, Jason: "lets clean it up ... if left over lets remoe it"):
        // only the agent windows use them, and Penpal has none. Their saved values stay as they are.
        if Flavor.current.has(.missions) || Flavor.current.has(.chat) {
        Section("Agents") {
            Picker("Fuel in", selection: Binding(
                get: { UserDefaults.standard.string(forKey: Fuel.unitKey) ?? "tokens" },
                set: { UserDefaults.standard.set($0, forKey: Fuel.unitKey) })) {
                Text("Tokens").tag("tokens")
                Text("API value").tag("api")
            }
            .pickerStyle(.segmented)
            .help(Fuel.help)
            Picker("Clock", selection: Binding(
                get: { Clock.style }, set: { UserDefaults.standard.set($0, forKey: Clock.key); AgentStore.shared.refresh() })) {
                Text("Match the Mac").tag("system")
                Text("12-hour (8:00 PM)").tag("12")
                Text("24-hour (20:00)").tag("24")
            }
            Toggle("Show what each agent reads under its circle", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "roster.notes") },
                set: { UserDefaults.standard.set($0, forKey: "roster.notes") }))
        }
        }
        // Claude History's own settings together (#313).
        Section {
            Toggle("Opens with the sessions list", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "history.sessionsOpen") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "history.sessionsOpen") }))
            Toggle("Developer tools in its menus", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "dev.tools") },
                set: { UserDefaults.standard.set($0, forKey: "dev.tools") }))
        } header: {
            Text("Claude History")
        } footer: {
            Text("Developer tools: copy a session's ID, show its transcript file, resume it in Terminal, or start a new session in its folder.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        Section("Troubleshooting") {
            Button("Permissions…") { Welcome.open() }
            Button("Show log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
        }
    }


    @ViewBuilder private func part(_ f: Feature, _ label: String? = nil) -> some View {
        if Flavor.current.has(f) {
            Toggle(label ?? f.label, isOn: features.binding(f)).disabled(!Features.allowed(f))
        }
    }

    @ViewBuilder private var dockPane: some View {
        Section("Dock") {
            Toggle("Show the dock", isOn: $overlay.dockOpen)
            if Features.on(.pin) { Toggle("Pin the dock to Claude's window (it rides along the window's edge)", isOn: $overlay.pinned) }
            part(.makeRoom)
            // One choice for the row (#313): where it sits, or none (the old "Session row" switch).
            if Features.allowed(.sessions) {
                Picker("Search, New, Window", selection: Binding(
                    get: { let _ = features.version; return !Features.on(.sessions) ? "hidden" : overlay.rowAbove ? "above" : "below" },
                    set: { v in
                        features.set(.sessions, v != "hidden")
                        if v != "hidden" { overlay.rowAbove = v == "above" }
                    })) {
                    Text("Above Highlight").tag("above")
                    Text("Below Highlight").tag("below")
                    Text("Hidden").tag("hidden")
                }
            }
        }
        // To try, live (#273): the panel for light and for dark, and the tiles.
        Section {
            Picker("Background, light", selection: penSetting(DockLook.lightKey, "glass")) {
                ForEach(DockLook.lights, id: \.key) { b in
                    Label { Text(b.label) } icon: { Image(nsImage: swatch(DockLook.color(b.key) ?? NSColor(white: 0.88, alpha: 0.6))) }.tag(b.key)
                }
            }
            Picker("Background, dark", selection: penSetting(DockLook.darkKey, "glass")) {
                ForEach(DockLook.darks, id: \.key) { b in
                    Label { Text(b.label) } icon: { Image(nsImage: swatch(DockLook.color(b.key) ?? NSColor(white: 0.3, alpha: 0.6))) }.tag(b.key)
                }
            }
            Picker("Tiles", selection: penSetting(DockLook.tilesKey, "raised")) {
                ForEach(DockLook.tileStyles, id: \.key) { Text($0.label).tag($0.key) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Glass is the system's own material, as the dock has always been. Raised tiles sit up off the panel; Flat is the old look; Tinted washes each tile in its icon's colour.")
                .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }

        if Flavor.current.has(.commands) || Flavor.current.has(.history) || Flavor.current.has(.usage) {
            Section {
                part(.commands, "Claude Commands: every menu command in Claude, one click each")
                part(.history, "Claude History: your sessions, prompts, tokens and pictures")
                part(.usage, "Usage meter: your plan's limits, read every 15 minutes")
            } header: {
                Text("Windows")
            } footer: {
                Text("History (⌘Y) and Usage open from the menu bar icon's menu, and the \(AppName.shown) menu while it's in front. The usage meter checks your plan's limits in the background every 15 minutes; Usage opens either way.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var guidePane: some View {
        Section {
            part(.guide)
        } footer: {
            Text("Ask how to do something in any app; \(AppName.shown) rings each thing to click, in order. It uses your own Claude plan, through Claude Code on this Mac.")
                .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        if Features.on(.guide) {
            GuideSeesView()
            Section {
                // Whole screen unless you say (#263): Jason ran Vercel and Porkbun side by side.
                Toggle("Only the app in front", isOn: Binding(get: { let _ = labsState.version; return Guide.frontOnly },
                                                              set: { UserDefaults.standard.set($0, forKey: Guide.frontOnlyKey); labsState.version += 1 }))
            } header: {
                Text("What it reads")
            } footer: {
                Text("Off: every window you can see, so steps can point at two windows side by side. On: only the app in front, a little faster.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Colour", selection: ringSetting(RingStyle.colorKey, "red")) {
                    ForEach(RingStyle.colors, id: \.key) { c in
                        Label { Text(c.label) } icon: { Image(nsImage: swatch(c.color)) }.tag(c.key)
                    }
                }
                Picker("Shape", selection: ringSetting(RingStyle.shapeKey, "box")) {
                    Text("Box that hugs the control").tag("box")
                    Text("Circle").tag("circle")
                }
                Toggle("Blink", isOn: Binding(get: { let _ = labsState.version; return RingStyle.blink },
                                              set: { UserDefaults.standard.set($0, forKey: RingStyle.blinkKey); labsState.version += 1; Guide.restyle() }))
                RingPreview(version: labsState.version).frame(height: 150)
            } header: {
                Text("Rings")
            } footer: {
                Text("Each thing to click gets a numbered ring. Changes show on the rings at once.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    // Enhance (#293, Jason: "can you add an enahcne section that allows the user to select the model for 'enhance wiht
    // claude'?"): which model rewrites your ask. Sonnet 5.5 unless you pick another, as 1.0.1 did.
    // Magic (#307, Jason: "maybe add a magic section, basically its 'models' section above guide me so users can set the
    // model for guide me and enhance ... we can move enhance content there and remove enahcne me section"): one picker
    // each, the same rows as before. Guide me's rings and what it sees stay in Guide me.
    @ViewBuilder private var magicPane: some View {
        Section {
            Picker("Model", selection: Binding(get: { let _ = labsState.version; return Guide.pickedModel },
                                               set: { Guide.pick($0); labsState.version += 1 })) {
                ForEach(Guide.models, id: \.id) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name)
                        Text(m.note).font(.caption).foregroundStyle(.secondary)
                    }.tag(m.id)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } header: {
            Text("Guide me")
        } footer: {
            Text("The model that reads your screen and rings each thing to click. Times are to the first ring, from a ready Claude on this Mac. Haiku 4.5 runs with thinking off. If your Claude Code can't run the one you pick, Guide me says so and the closest one it has rings instead.")
                .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        enhancePane
    }

    @ViewBuilder private var enhancePane: some View {
        Section {
            Picker("Model", selection: Binding(get: { let _ = labsState.version; return Enhance.pickedModel },
                                               set: { Enhance.pick($0); labsState.version += 1 })) {
                ForEach(Enhance.models, id: \.id) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name)
                        Text(m.note).font(.caption).foregroundStyle(.secondary)
                    }.tag(m.id)
                }
            }
            .pickerStyle(.inline).labelsHidden()  // one row each, the pick ticked, as System Settings lists choices
        } header: {
            Text("Enhance")
        } footer: {
            Text("The model that rewrites your ask into a prompt. Times are typical, from a ready Claude on this Mac; a big ask with many pictures takes longer. Haiku 5.5 runs at low effort, Haiku 4.5 with thinking off. If your Claude Code can't run the one you pick, Enhance says so and the closest one it has answers. Your next Enhance uses the new pick, on your own Claude plan, through Claude Code.")
                .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func penSetting(_ key: String, _ standard: String) -> Binding<String> {
        Binding(get: { let _ = labsState.version; return UserDefaults.standard.string(forKey: key) ?? standard },
                set: { UserDefaults.standard.set($0, forKey: key); labsState.version += 1 })
    }
    private func ringSetting(_ key: String, _ standard: String) -> Binding<String> {
        Binding(get: { let _ = labsState.version; return UserDefaults.standard.string(forKey: key) ?? standard },
                set: { UserDefaults.standard.set($0, forKey: key); labsState.version += 1; Guide.restyle() })
    }

    // Lenses: what you type (;cat, ;ss…) and what it pastes, set by set.
    @ViewBuilder private var lensesPane: some View {
        Section {
            // Two switches that read alike (#313): all of Snippets, and only the typing shortcut.
            Toggle("Snippets in the dock and menus", isOn: features.binding(.lenses)).disabled(!Features.allowed(.lenses))
            if expander.trusted {
                Toggle("Type ;name in Claude to paste a snippet", isOn: $expander.enabled).disabled(!Features.on(.lenses))
            } else {
                Button("Allow Accessibility…") { expander.requestAccess() }
            }
            // How your Claude talks (#270, out of the Snippets menu): the snippet Guide me and Enhance follow when they
            // answer you; Default, none, as they're written.
            Picker(Flavor.current.has(.chat) ? "Agents talk" : "Claude's style", selection: Binding(
                get: { let _ = labsState.version; return AgentStore.shared.mode ?? "" },
                set: { AgentStore.shared.setMode($0.isEmpty ? nil : $0); labsState.version += 1 })) {
                Text("Default").tag("")
                Divider()
                ForEach(expander.lenses.names(), id: \.self) { Text($0).tag($0) }
            }
            .help(Flavor.current.has(.chat) ? "The snippet your agents follow when they talk to you" : "The snippet Guide me and Enhance follow when they answer you")
            Button("Edit snippets…") { LensWindow.open(expander.lenses) }
            Button("Restore default snippets…") { expander.lenses.restoreDefaultsAsking(); labsState.version += 1 }
        } footer: {
            Text("A snippet pastes exactly its text. {n} in a snippet counts up: img{n} → img1, img2…")
                .foregroundStyle(.secondary)
        }
        Section("Sets") {
            ForEach(expander.lenses.sets(), id: \.self) { set in
                Toggle(isOn: Binding(get: { expander.lenses.isOn(set) }, set: { expander.lenses.setOn(set, $0); labsState.version += 1 })) {
                    Text(LensStore.title(set)) + Text("  \(expander.lenses.lenses(in: set).count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var screenshotsPane: some View {
        if Flavor.current == .penpal { Section { part(.capture) } }
        Section("Highlight") {
            if highlighter.canCapture {
                Toggle("Start with \(highlighter.keysLabel) (hold, then drag)", isOn: $highlighter.enabled)
                Picker("Keys", selection: $highlighter.trigger) {
                    ForEach(Highlighter.triggers, id: \.label) { Text($0.label).tag($0.flags.rawValue) }
                }
                .disabled(!highlighter.enabled)
            Picker("Mode", selection: $highlighter.mode) {
                ForEach(Highlighter.Mode.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
                Picker("Finish when I let go of", selection: $highlighter.finishOnKeys) {
                    Text("The mouse: one drag").tag(false)
                    Text("The keys: draw as much as I like first").tag(true)
                }
                .disabled(!highlighter.enabled)
            } else {
                Button("Allow Screen Recording…") { highlighter.requestCapture() }
            }
            Toggle("Number pictures: \u{1F5BC} 1, \u{1F5BC} 2, …", isOn: $numberPictures)
                .help("Each picture pasted into Claude gets a label, so your words can say “in \u{1F5BC} 2”. Counting starts over when you send the message (Return in Claude), after five quiet minutes, or from the menu bar's Reset. Removing a picture in Claude doesn't renumber the rest: \(AppName.shown) can't see Claude's attachments")
            // How far apart the pictures sit in Claude's box (#248, Jason: "allowing users to select # of lines. can be 0").
            Picker("Lines between pictures", selection: $pictureLines) {
                ForEach(0...5, id: \.self) { Text($0 == Paster.linesDefault ? "\($0) (default)" : "\($0)").tag($0) }
            }
            .disabled(!numberPictures)
        }
        Section {
            Picker("Send to", selection: $target) {
                ForEach(Paster.Target.allCases.filter { $0 != .chat || Flavor.current.has(.chat) }, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Highlight and snippet buttons")
        } footer: {
            Text(target == .claude
                 ? "Claude comes forward and the paste lands in its message box, from any app. " + (Flavor.current.has(.chat) ? "If Claude is closed, screenshots go to \(AppName.shown)'s Chat." : "If Claude is closed, a picture waits on the clipboard.")
                 : target == .chat ? "Screenshots open in \(AppName.shown)'s Chat, ready for your question."
                 : target == .clipboard ? "Nothing is pasted for you. You'll hear a pop, then press ⌘V in any app."
                 : "Pastes into whatever app you are in.")
                .foregroundStyle(.secondary)
        }
        // The pen (#272), as Guide me's rings: its colour and width, with a preview. The picture pasted into Claude carries it.
        Section {
            Picker("Colour", selection: penSetting(PenStyle.colorKey, "pink")) {
                ForEach(RingStyle.colors, id: \.key) { c in
                    Label { Text(c.label) } icon: { Image(nsImage: swatch(c.color)) }.tag(c.key)
                }
            }
            Picker("Width", selection: penSetting(PenStyle.widthKey, "medium")) {
                ForEach(PenStyle.widths, id: \.key) { Text($0.label).tag($0.key) }
            }
            .pickerStyle(.segmented)
            PenPreview(version: labsState.version).frame(height: 96)
        } header: {
            Text("Pen")
        } footer: {
            Text("What you draw with \(highlighter.keysLabel), on the screen and in the picture that goes into Claude.")
                .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        CaptureDiagnosticView()  // at the bottom, folded: Troubleshooting (#313)
    }

}



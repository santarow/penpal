import AppKit
import Foundation
import SwiftUI

// Every feature has a switch. Four things decide whether it runs:
//   1. the organization's policy (a file an admin puts in /Library, see Policy): off means off
//   2. Workbench mode: only what the lite (App Store) build does, nothing that runs Claude
//   3. a release build (KITE_RELEASE): what isn't in this release can't be reached at all
//   4. your own toggle in Settings → Features
// Features.on(x) is all four; Features.allowed(x) is the first three (what may run at all).
enum Feature: String, CaseIterable, Identifiable {
    // Jetpack: helps you use the Claude app; no AI of its own
    case capture, lenses, commands, usage, history, sessions, pin, makeRoom
    // Mission Control: runs your own claude for you
    case guide, voice, chat, missions, telegram, phone, location, webStatus, board

    var id: String { rawValue }
    var jetpack: Bool { [.capture, .lenses, .commands, .usage, .history, .sessions, .pin, .makeRoom].contains(self) }
    var label: String {
        switch self {
        case .capture: "Highlight: hold your keys and draw; the picture goes into Claude"
        case .lenses: "Snippets: the dock row and ;name expansion"
        case .commands: "Claude Commands window"
        case .usage: "Usage meter"
        case .history: "Claude History: sessions, prompts, tokens, images"
        case .sessions: "Session row: New, Search, Window"
        case .pin: "Pin the dock to Claude's window"
        case .makeRoom: "Make room: Claude narrows so the open dock fits beside it"
        case .guide: "Guide me: it rings each thing to click, in any app"
        case .voice, .telegram, .phone: "Not in Penpal"
        case .chat: "Chat and agent tiles"
        case .missions: "Missions: routines, watches and tasks"
        case .location: "Location for agents"
        case .webStatus: "Web status page"
        case .board: "Task board: the checklist for your repos and missions"
        }
    }
    // Where the user's own toggle is stored. Missions keep their old Labs key.
    var key: String { self == .missions ? "labs.topics" : "feature.\(rawValue)" }
    var defaultOn: Bool {
        // Penpal (#245, #247): everything it has, but the usage meter (it runs /usage every 15 minutes).
        if Flavor.current == .penpal { return self != .usage }
        return ![.webStatus, .phone].contains(self)
    }  // missions and make room: on (Workshop is the full app)
}

// What the user sees the app called: Workshop (a dev build says Workshop Dev). From the bundle, so
// hints like "turn on Workshop in System Settings" match the name macOS shows there.
enum AppName {
    static let shown = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? Flavor.current.name
}

@MainActor
final class Features: ObservableObject {
    static let shared = Features()
    @Published private(set) var version = 0  // bumped on any change, so views and features re-check

    @Published var jetpackPreview = UserDefaults.standard.bool(forKey: "jetpackPreview") {
        didSet { UserDefaults.standard.set(jetpackPreview, forKey: "jetpackPreview"); changed() }
    }

    // Not in 1.0: unfinished, broken, or needing the phone or the network (1.0 is local-first).
    // In a release build they can't be reached: no switch, no button, no menu item.
    // Penpal's release has Guide me (#247, Jason: "lets add ... Guide me (screen guide)").
    static var notInRelease: Set<Feature> { Flavor.current == .penpal ? [.board, .webStatus, .location] : [.board, .webStatus, .location, .guide] }
    static var isRelease: Bool {
        #if KITE_RELEASE
        true
        #else
        false
        #endif
    }
    // Workbench (lite) or Workshop (full): the same app; Workbench shows only what the lite build has.
    var workbench: Bool { jetpackPreview }

    static func allowed(_ f: Feature) -> Bool {
        if !Flavor.current.has(f) { return false }  // the other SantaRow app's (#209)
        if isRelease && notInRelease.contains(f) { return false }
        if Policy.shared.disabled.contains(f.rawValue) { return false }
        if shared.jetpackPreview && !f.jetpack { return false }
        return true
    }
    static func on(_ f: Feature) -> Bool {
        allowed(f) && (UserDefaults.standard.object(forKey: f.key) as? Bool ?? f.defaultOn)
    }
    func set(_ f: Feature, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: f.key)
        changed()
    }
    func binding(_ f: Feature) -> Binding<Bool> {
        Binding(get: { Features.on(f) }, set: { self.set(f, $0) })
    }
    private func changed() {
        version += 1
        NotificationCenter.default.post(name: Self.changedNote, object: nil)
    }
    static let changedNote = Notification.Name("kite.features.changed")
}

// What an organization allows. An admin (or MDM) puts this file in place; Kite and bin/kite
// both read it, and a feature it turns off can't be turned on in Settings.
//
//   /Library/Application Support/Kite/policy.json   enforced (root-owned, users can't change it)
//   ~/.kite/policy.json                             the same, for trying a policy out (not enforced)
//
//   {"message": "Managed by Acme IT",
//    "disable": ["telegram", "location", "webStatus"],     feature ids, as in Feature
//    "deny_tools": ["WebFetch"],                           Claude Code tools agents may not use
//    "deny_mcp": ["kite-mac"]}                             Kite's MCP servers agents may not use
struct Policy {
    // SantaRow's (#310); the old Kite folder is still read for one version.
    static let enforcedPath = FileManager.default.fileExists(atPath: "/Library/Application Support/SantaRow/policy.json")
        ? "/Library/Application Support/SantaRow/policy.json" : "/Library/Application Support/Kite/policy.json"
    static let userPath = Kite.read("policy.json").path
    static let shared = Policy.load()

    var disabled: Set<String> = []
    var deniedTools: [String] = []
    var deniedMCP: [String] = []
    var message: String?
    var source: String?     // which file, or nil when there's none
    var enforced = false

    static func load() -> Policy {
        for (path, enforced) in [(enforcedPath, true), (userPath, false)] {
            guard let data = FileManager.default.contents(atPath: path),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var p = Policy()
            p.disabled = Set(d["disable"] as? [String] ?? [])
            p.deniedTools = d["deny_tools"] as? [String] ?? []
            p.deniedMCP = d["deny_mcp"] as? [String] ?? []
            p.message = d["message"] as? String
            p.source = path
            p.enforced = enforced
            Log.line("policy: \(path) (\(enforced ? "enforced" : "trial")): off \(p.disabled.sorted())")
            return p
        }
        return Policy()
    }
}

// Kite's look, for all its windows and the dock: follow the Mac, or always light, or always dark.
@MainActor
final class Appearance: ObservableObject {
    static let shared = Appearance()
    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { self == .system ? "Match the Mac" : self == .light ? "Light" : "Dark" }
    }
    @Published var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appearance"); apply() }
    }
    func apply() {
        NSApp.appearance = switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

// Kite's window surfaces, calm in both themes like System Settings: the sidebar and the content
// share one solid background (no see-through sidebar tinted by the desktop), and cards sit a shade
// apart with a hairline edge.
enum Palette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.75)
    })
    static let edge = Color(nsColor: .separatorColor)
}


// A symbol on a small rounded tile of color, white glyph: the System Settings look.
// A text box that reads as one (after #273's SDK, the window and a text box are both white, and the boxes vanished:
// "wow i cant see antthing"): a faint fill and a hairline edge, in light and dark. subtle: a container, as Enhance's
// Pictures, a shade lighter than a box you type in.
struct FieldBox: ViewModifier {
    var radius: CGFloat
    var subtle = false
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let dark = scheme == .dark
        content
            .background(shape.fill(Color.primary.opacity(subtle ? (dark ? 0.04 : 0.025) : (dark ? 0.07 : 0.045))))
            .overlay(shape.strokeBorder(Color.primary.opacity(subtle ? (dark ? 0.1 : 0.08) : (dark ? 0.18 : 0.14)), lineWidth: 1))
    }
}
extension View {
    func fieldBox(radius: CGFloat = 8, subtle: Bool = false) -> some View { modifier(FieldBox(radius: radius, subtle: subtle)) }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26))
    }
}

extension Palette {
    // Penpal's tiles, each its own colour (#257 follow-up, Jason: "too much of that magenta color"):
    // Snippets orange, Enhance the violet of Penpal's own icon, Guide me keeps its pink.
    static let snippets = Color.orange
    static let enhance = Color(red: 0.42, green: 0.33, blue: 0.80)

}

// Times the way you like them: 12-hour (8:00 PM), 24-hour (20:00), or as the Mac does it.
// Settings → General → Clock. Pickers follow it too (through `locale`).
enum Clock {
    static let key = "clock.style"  // "system", "12", "24"
    static var style: String { UserDefaults.standard.string(forKey: key) ?? "system" }
    static var uses24: Bool {
        switch style {
        case "24": return true
        case "12": return false
        default: return !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h").contains("a")
        }
    }
    static var locale: Locale { style == "system" ? .current : Locale(identifier: uses24 ? "en_GB" : "en_US") }
    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = uses24 ? "HH:mm" : "h:mm a"; return f.string(from: d)
    }
    // "20:00" (how schedules store it) → "20:00" or "8:00 PM"
    static func hhmm(_ s: String) -> String {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, let d = Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: .now) else { return s }
        return time(d)
    }
    static func dayTime(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated)) + " " + time(d) }
}

// Something new to read: a red dot, like Messages' (without the number).
struct UnreadBadge: View {
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(Color.red).frame(width: size, height: size).help("New result")
    }
}

// Fuel: what runs spent, in tokens (what a subscription spends, measured on every run) or in
// dollars at API prices (claude's own figure; on a subscription nobody pays it). Settings →
// Appearance picks which one shows.
struct Fuel {
    var cost: Double = 0
    var tokens: Int = 0
    static let unitKey = "fuel.unit"  // "tokens" (default) or "api"
    static var inTokens: Bool { UserDefaults.standard.string(forKey: unitKey) != "api" }
    static func + (a: Fuel, b: Fuel) -> Fuel { Fuel(cost: a.cost + b.cost, tokens: a.tokens + b.tokens) }
    func divided(by n: Int) -> Fuel { Fuel(cost: cost / Double(max(n, 1)), tokens: tokens / max(n, 1)) }
    var value: Double { Self.inTokens ? Double(tokens) : cost }  // for proportions
    static func count(_ t: Int) -> String {
        t >= 1_000_000 ? String(format: "%.1fM", Double(t) / 1e6) : t >= 10_000 ? "\(t / 1000)k" : t >= 1000 ? String(format: "%.1fk", Double(t) / 1e3) : "\(t)"
    }
    var short: String { Self.inTokens ? Self.count(tokens) : String(format: "$%.2f", cost) }  // "38k", "$0.22"
    var label: String { Self.inTokens ? Self.count(tokens) + " tokens" : String(format: "$%.2f at API prices", cost) }
    static let help = "Fuel: tokens are every token the runs went through (input, cache and output), which is what your subscription spends. API value is what the same runs would cost on the paid API (claude's own figure); on a subscription you don't pay it. Pick one in Settings → Appearance."
}
extension Sequence where Element == Run {
    var fuel: Fuel { reduce(Fuel()) { $0 + $1.fuel } }
}

// Where the fuel went, as one bar split by who spent it, with a legend under it.
struct FuelBar: View {
    struct Part: Identifiable { let id: String; let fuel: Fuel; let color: Color }
    @AppStorage(Fuel.unitKey) private var unit = "tokens"  // redraws when the unit changes
    let parts: [Part]
    var legend = true
    var body: some View {
        let total = max(parts.map(\.fuel.value).reduce(0, +), 0.0001)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(parts.filter { $0.fuel.value > 0 }) { p in
                        Rectangle().fill(p.color.gradient).frame(width: max(3, geo.size.width * p.fuel.value / total))
                            .help("\(p.id): \(p.fuel.label) (" + String(format: "%.0f%%", p.fuel.value / total * 100) + ")")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 7)
            if legend {
                HStack(spacing: 10) {
                    ForEach(parts) { p in
                        HStack(spacing: 4) {
                            Circle().fill(p.color).frame(width: 7, height: 7)
                            Text(p.id).font(.caption.weight(.medium))
                            Text(p.fuel.short).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}


// Fill: a window grows to the whole screen, stopping short of Kite's dock (like Rectangle's
// Maximize, but leaving the dock visible). A second click puts it back.
@MainActor
enum WindowFill {
    private static var before: [ObjectIdentifier: NSRect] = [:]
    static func isFilled(_ w: NSWindow?) -> Bool { w.map { before[ObjectIdentifier($0)] != nil } ?? false }
    static func toggle(_ w: NSWindow?) {
        guard let w, let screen = w.screen ?? NSScreen.main else { return }
        let key = ObjectIdentifier(w)
        if let old = before[key] {
            before[key] = nil
            w.setFrame(old, display: true, animate: true)
            return
        }
        var area = screen.visibleFrame
        if let dock = Overlay.current?.shownFrame, dock.intersects(area) {
            // The dock on the right: stop at its left edge; on the left: start after it.
            if dock.midX > area.midX { area.size.width = max(600, dock.minX - 8 - area.minX) }
            else { let right = area.maxX; area.origin.x = dock.maxX + 8; area.size.width = max(600, right - area.origin.x) }
        }
        before[key] = w.frame
        w.setFrame(area, display: true, animate: true)
    }
}

// The button, for a window's toolbar.
final class FillState: ObservableObject { @Published var tick = 0 }
struct FillButton: View {
    @StateObject private var state = FillState()  // redraws the icon after a toggle
    var body: some View {
        let _ = state.tick
        Button { WindowFill.toggle(NSApp.keyWindow); state.tick += 1 } label: { Label("Fill the screen", systemImage: WindowFill.isFilled(NSApp.keyWindow) ? "arrow.up.right.and.arrow.down.left" : "arrow.down.left.and.arrow.up.right") }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .help("Fill the screen up to \(AppName.shown)'s dock (⌃⌘F); again to put it back")
    }
}

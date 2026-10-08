import AppKit
import Charts
import SwiftUI

// Usage: your plan limits as Claude reports them, and tokens from local Claude Code
// transcripts (bin/kite usage). Every breakdown adds back up to the total, and says so.
struct UsageReport: Decodable {
    struct Tokens: Decodable {
        let input, output, cache_write, cache_read: Int
        var total: Int { input + output + cache_write + cache_read }
    }
    struct Window: Decodable { let name: String; let pct: Int; let resets: String; let resetsAt: Double? }
    struct Limits: Decodable {
        let at: Double
        let windows: [Window]
        let notes: [String]?
    }
    let days: Int
    let from: String
    let total: Tokens
    let by_day, by_source, by_model, by_project: [String: Tokens]
    let limits: Limits?
    let ties_out: Bool
    let requests_24h: Int?
    let requests_7d: Int?
    let period: String?
    let period_requests: Int?
    let history: [[String: Double]]?  // /usage readings: "at" plus one % per window
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var report: UsageReport?
    @Published var loading = false
    @Published var checking = false
    @Published var error: String?
    // today, 7, 30, year or all; kept between openings
    @Published var period = UserDefaults.standard.string(forKey: "usagePeriod") ?? "7" {
        didSet { UserDefaults.standard.set(period, forKey: "usagePeriod"); load() }
    }
    static let periods: [(String, String)] = [("today", "Today"), ("7", "7 days"), ("30", "30 days"), ("year", "This year"), ("all", "All time")]
    var tokensShown: Bool { ["today", "7"].contains(period) }  // the periods /usage can confirm
    private var ticker: Timer?
    var visible: () -> Bool = { false }

    // While the window is open: limits and tokens every 60 s. Both are free: limits come from
    // Claude Code's /usage (no model call), tokens from local transcripts.
    func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard self.visible(), !self.loading, !self.checking else { return }
                self.checkLimits()
            }
        }
    }

    // Shows the last report at once, then the fresh one when it's ready.
    func load() {
        let p = tokensShown ? period : "7"
        if report == nil || report?.period != p,
           let data = try? Data(contentsOf: Kite.read("usage/last-\(p).json")),
           let cached = try? JSONDecoder().decode(UsageReport.self, from: data) {
            report = cached
        }
        loading = true
        run(["usage", p]) { data in
            self.loading = false
            if let data, let r = try? JSONDecoder().decode(UsageReport.self, from: data) { self.report = r; self.error = nil }
            else if self.report == nil { self.error = "Couldn't read usage. See the log." }
        }
    }

    // Claude Code's /usage, run headless: fresh limits for zero tokens. Then tokens.
    // /usage and the token scan run side by side; limits are folded in when /usage answers.
    func checkLimits() {
        checking = true
        load()
        run(["limits"]) { _ in
            self.checking = false
            self.load()
        }
    }

    private func run(_ args: [String], done: @escaping @MainActor (Data?) -> Void) {
        guard let root = Kite.root else { return done(nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli)
        p.arguments = args
        var env = Kite.engineEnv
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { p in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let ok = p.terminationStatus == 0
            Task { @MainActor in
                if !ok { Log.line("helper \(args.first ?? "") failed") }
                done(ok ? data : nil)
            }
        }
        do { try p.run() } catch { done(nil) }
    }
}

@MainActor
enum UsageWindow {
    private static var window: NSWindow?
    private static let model = UsageModel()

    static func toggle() {
        if let w = window, w.isVisible, w.isKeyWindow, NSApp.isActive { return w.performClose(nil) }
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "\(AppName.shown) Usage"
            let host = NSHostingView(rootView: UsageView(model: model))
            host.sizingOptions = [.minSize]
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            return w
        }()
        model.visible = { window?.isVisible == true }
        model.checkLimits()
        model.startTicking()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

struct UsageView: View {
    @ObservedObject var model: UsageModel
    @StateObject private var activity = ActivityModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.loading || model.checking, model.report != nil {
                    Label("Updating…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.tertiary)
                }
                if let r = model.report {
                    limits(r.limits)
                    tokens(r)
                    Divider().padding(.vertical, 6)
                    ActivitySection(model: activity)
                } else if let e = model.error {
                    Text(e).foregroundStyle(.red)
                } else {
                    ProgressView("Reading your transcripts…")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    // ---- Plan limits ----

    @ViewBuilder private func limits(_ l: UsageReport.Limits?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Plan limits").font(.title3.bold())
                if l?.windows.isEmpty == false {
                    Label(Self.verified.label, systemImage: Self.verified.icon).font(.caption).foregroundStyle(.secondary).help(Self.verified.help)
                }
                Text("refreshes every minute").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button { model.checkLimits() } label: {
                    Label(model.checking ? "Checking…" : "Check now", systemImage: "arrow.clockwise")
                }
                .disabled(model.checking)
                .help("Runs Claude Code's /usage: no model call, no tokens")
            }
            if let l, !l.windows.isEmpty {
                ForEach(l.windows, id: \.name) { meter($0) }
                Text("From Claude Code's /usage, \(Date(timeIntervalSince1970: l.at).formatted(.relative(presentation: .named))). The same limits Claude Code and \(AppName.shown)'s agents draw from.")
                    .font(.caption).foregroundStyle(.secondary)
                if let notes = l.notes, !notes.isEmpty {
                    DisclosureGroup("What's using your limits (from /usage)") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                                Text(n.trimmingCharacters(in: .whitespaces))
                                    .font(n.hasPrefix("  ") ? .callout : .callout.weight(.medium))
                                    .foregroundStyle(n.hasPrefix("  ") ? .secondary : .primary)
                                    .padding(.leading, n.hasPrefix("  ") ? 12 : 0)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                    .font(.callout)
                }
            } else {
                Text("No limit reading yet. Press Check now.").foregroundStyle(.secondary)
            }
        }
    }

    // Laid out like Claude's own usage panel: name, when it resets, percent.
    private func meter(_ w: UsageReport.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(w.name).fontWeight(.medium)
                Spacer()
                Text(Self.resets(w)).foregroundStyle(.secondary)
                Text("\(w.pct)%").monospacedDigit().frame(minWidth: 40, alignment: .trailing)
            }
            ProgressView(value: min(Double(w.pct) / 100, 1)).tint(w.pct >= 80 ? .red : w.pct >= 50 ? .orange : .accentColor)
        }
    }

    // Today: "Resets in 2 hr 7 min". Later: "Resets Sat 11:00 PM".
    static func resets(_ w: UsageReport.Window) -> String {
        guard let t = w.resetsAt else { return w.resets.isEmpty ? "" : "Resets \(w.resets)" }
        let when = Date(timeIntervalSince1970: t)
        guard Calendar.current.isDateInToday(when) else {
            return "Resets " + when.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        let mins = max(0, Int(when.timeIntervalSinceNow / 60))
        return mins >= 60 ? "Resets in \(mins / 60) hr \(mins % 60) min" : "Resets in \(mins) min"
    }

    // Readings saved before the names matched Claude's panel.
    static let oldNames = ["5-hour session": "5-hour limit", "Week · all models": "Weekly · all models", "Week · Fable": "Weekly · Fable"]

    // The picked period as a time range: today from midnight, else back from now; all time from the first reading.
    static func range(_ period: String, first: Date?) -> ClosedRange<Date> {
        let now = Date.now, cal = Calendar.current
        let start: Date = switch period {
        case "today": cal.startOfDay(for: now)
        case "7": now.addingTimeInterval(-7 * 86400)
        case "30": now.addingTimeInterval(-30 * 86400)
        case "year": cal.date(from: cal.dateComponents([.year], from: now)) ?? now
        default: min(first ?? cal.startOfDay(for: now), cal.startOfDay(for: now))
        }
        return start...now
    }

    // How your limits moved, from Kite's saved /usage readings, over the whole picked period.
    @ViewBuilder private func history(_ raw: [[String: Double]], current: UsageReport.Limits?) -> some View {
        let points: [(at: Date, name: String, pct: Double)] = raw.flatMap { p -> [(at: Date, name: String, pct: Double)] in
            guard let at = p["at"] else { return [] }
            return p.compactMap { k, v in k == "at" ? nil : (Date(timeIntervalSince1970: at), Self.oldNames[k] ?? k, v) }
        }
        let first = points.map(\.at).min()
        let span = Self.range(model.period, first: first)
        // The newest reading, carried to now, so each line reaches the right edge.
        let now = (current?.windows ?? []).map { (at: Date.now, name: $0.name, pct: Double($0.pct)) }
        let shown = (points + now).filter { span.contains($0.at) }
        VStack(alignment: .leading, spacing: 6) {
            Text("History").font(.headline).padding(.top, 6)
            Chart(Array(shown.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.at), y: .value("%", p.pct))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(by: .value("Limit", p.name))
            }
            .chartXScale(domain: span)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { v in
                    AxisGridLine()
                    AxisValueLabel(format: model.period == "today" ? .dateTime.hour() :
                                   ["7", "30"].contains(model.period) ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated))
                }
            }
            .frame(height: 160)
            Text(first.map { "From /usage, recorded since \($0.formatted(.dateTime.month(.abbreviated).day().hour().minute())), every 15 minutes while \(AppName.shown) runs. Nothing before that is shown." }
                 ?? "\(AppName.shown) saves each /usage reading, every 15 minutes while it runs. The chart fills in from here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // ---- Tokens ----

    @ViewBuilder private func tokens(_ r: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.period) {
                ForEach(UsageModel.periods, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            history(r.history ?? [], current: r.limits)
            Divider().padding(.vertical, 6)
            if model.tokensShown { tokenDetail(r) } else {
                let t = Self.trust(model.period)  // "Not counted", and why
                Label("\(t.label): \(t.help)", systemImage: t.icon).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // Today and 7 days only: counted from transcripts, never saved. /usage prints no token count, so
    // the tokens can't be confirmed; it does print request counts, and ours are checked against them.
    @ViewBuilder private func tokenDetail(_ r: UsageReport) -> some View {
        let trust = Self.trust(r.period ?? "7")
        let tie = Self.requestsTieOut(r)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Label(trust.label, systemImage: trust.icon).help(trust.help)
                Label(tie.label, systemImage: tie.icon).foregroundStyle(tie.color).help(tie.help)
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text("Tokens, \(UsageModel.periods.first { $0.0 == r.period }?.1.lowercased() ?? "last \(r.days) days")").font(.title3.bold())
                Text("live, not saved").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Label(r.ties_out ? "Adds up" : "Doesn't add up: a bug", systemImage: r.ties_out ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(r.ties_out ? Color.secondary : Color.red)
                    .help("Every breakdown below sums back to the total")
            }
            Text(Self.short(r.total.total)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("Cache reads", r.total.cache_read, r.total.total, "Claude re-reading the conversation so far")
                row("Cache writes", r.total.cache_write, r.total.total, "new context saved for re-reading")
                row("Output", r.total.output, r.total.total, "what Claude wrote")
                row("Fresh input", r.total.input, r.total.total, "new words not in the cache")
            }
            .font(.callout)

            Text("By day").font(.headline).padding(.top, 6)
            Chart(r.by_day.sorted { $0.key < $1.key }, id: \.key) { day, t in
                BarMark(x: .value("Day", String(day.suffix(5))), y: .value("Tokens", t.total))
            }
            .chartYAxis { AxisMarks { v in AxisValueLabel { if let n = v.as(Int.self) { Text(Self.short(n)) } }; AxisGridLine() } }
            .frame(height: 150)

            breakdown("Where from", r.by_source, r.total.total, name: { $0 == "kite" ? "\(AppName.shown)'s agents" : "Claude Code sessions" })
            breakdown("Projects", r.by_project, r.total.total, limit: 8, name: Self.project)
            breakdown("Models", r.by_model.filter { $0.value.total > 0 }, r.total.total, name: { $0 })
            Text("From Claude Code's own transcripts on this Mac (~/.claude/projects). Claude chats on claude.ai aren't stored locally, so they aren't counted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ n: Int, _ total: Int, _ note: String) -> some View {
        GridRow {
            Text(label)
            Text(Self.short(n)).monospacedDigit().gridColumnAlignment(.trailing)
            Text(Self.pct(n, total)).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(note).foregroundStyle(.secondary)
        }
    }

    private func breakdown(_ title: String, _ groups: [String: UsageReport.Tokens], _ total: Int,
                           limit: Int = 20, name: @escaping (String) -> String) -> some View {
        let sorted = groups.sorted { $0.value.total > $1.value.total }
        let shown = sorted.prefix(limit)
        let rest = sorted.dropFirst(limit).reduce(0) { $0 + $1.value.total }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).padding(.top, 6)
            ForEach(Array(shown), id: \.key) { key, t in bar(name(key), t.total, total) }
            if rest > 0 { bar("\(sorted.count - limit) more", rest, total) }  // so the list still adds up
        }
    }

    private func bar(_ label: String, _ n: Int, _ total: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).lineLimit(1).truncationMode(.middle).frame(width: 220, alignment: .leading)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(2, g.size.width * Double(n) / Double(max(total, 1))))
            }
            .frame(height: 10)
            Text("\(Self.short(n)) · \(Self.pct(n, total))").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
    }

    // "-Users-jason-repos-claude-kite--claude-worktrees-x-agents-chat" → "Kite: chat"
    static func project(_ dir: String) -> String {
        if let r = dir.range(of: "-agents-") { return "\(AppName.shown): " + dir[r.upperBound...].replacingOccurrences(of: "topic-", with: "topic ") }
        var s = dir.replacingOccurrences(of: "-Users-\(NSUserName())-", with: "~/")
        if let r = s.range(of: "--claude-worktrees-") { s = s[..<r.lowerBound] + " (worktree " + s[r.upperBound...] + ")" }
        return s.replacingOccurrences(of: "~/repos-", with: "")
    }

    // How sure each figure is: never show a number more confidently than the evidence (Metric Tree rule 5).
    // Plan limits are Claude's own numbers, read from /usage: the only figures here that are verified.
    // Tokens are counted from this Mac's transcripts, which /usage can't confirm (it prints no token
    // count). It does print request counts ("Last 24h · 851 requests"), and requestsTieOut checks ours
    // against them. Short label, the reason on hover.
    struct Trust { let label, icon, help: String }
    static let verified = Trust(label: "Verified", icon: "checkmark.seal",
                                help: "Claude's own numbers, read from Claude Code's /usage. Nothing here is worked out by \(AppName.shown).")
    static func trust(_ period: String) -> Trust {
        switch period {
        case "today": Trust(label: "From transcripts", icon: "doc.text.magnifyingglass",
                            help: "Counted from Claude Code's transcripts on this Mac, since midnight. /usage prints no token count, so these tokens aren't verified. Its request counts are checked beside this.")
        case "7": Trust(label: "From transcripts", icon: "doc.text.magnifyingglass",
                        help: "Counted from Claude Code's transcripts on this Mac, last 7 days. /usage prints no token count, so these tokens aren't verified. Its request counts are checked beside this.")
        default: Trust(label: "Not counted", icon: "info.circle",
                       help: "Tokens are shown for today and 7 days only, the periods /usage can check. Past that they'd be worked out from transcript files, which can be deleted or edited. The history above is /usage's own numbers.")
        }
    }

    // The one figure /usage can confirm: requests. bin/kite counts them as of the /usage reading, so both
    // sides count the same files over the same minute and should agree exactly. A request finishing in the
    // second or two between the two counts lands on one side only, so 1 or 2 apart is timing, not a bug.
    struct TieOut { let label, icon, help: String; let color: Color }
    static func requestsTieOut(_ r: UsageReport) -> TieOut {
        guard let d = r.requests_24h, let w = r.requests_7d else {
            return TieOut(label: "Requests not counted", icon: "questionmark.circle", help: "The token scan gave no request counts.", color: .secondary)
        }
        let ours = "\(d.formatted()) in 24 h, \(w.formatted()) in 7 d"
        guard let l = r.limits, let ud = Self.usageRequests(l.notes, "24h"), let uw = Self.usageRequests(l.notes, "7d") else {
            return TieOut(label: "Requests: \(ours). Not checked against /usage", icon: "questionmark.circle",
                          help: "The last limits reading came without /usage's own request counts. Press Check now.", color: .secondary)
        }
        let off = [("24 h", d, ud), ("7 d", w, uw)].filter { $0.1 != $0.2 }
        if off.isEmpty {
            return TieOut(label: "Requests tie out with /usage: \(ours)", icon: "checkmark.seal",
                          help: "Counted as of the /usage reading, and /usage counted the same.", color: .secondary)
        }
        let detail = off.map { "\($0.1.formatted()) here, \($0.2.formatted()) there in \($0.0)" }.joined(separator: "; ")
        let gap = off.map { abs($0.1 - $0.2) }.max() ?? 0
        if gap <= 2 {
            return TieOut(label: "Requests within \(gap) of /usage: \(detail)", icon: "clock",
                          help: "Both count this Mac's transcripts as of the /usage reading, a second or two apart, so a request finishing in between lands on one side only. Press Check now to read both again.", color: .secondary)
        }
        return TieOut(label: "Requests don't match /usage: \(detail)", icon: "exclamationmark.triangle",
                      help: "Both count this Mac's transcripts as of the /usage reading and should agree. More than a request or two apart is a bug hunt, not a caption.", color: .orange)
    }

    // /usage's own request counts, from its "Last 24h · 851 requests · 32 sessions" lines.
    static func usageRequests(_ notes: [String]?, _ window: String) -> Int? {
        guard let line = notes?.first(where: { $0.hasPrefix("Last \(window) ·") }) else { return nil }
        let parts = line.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts[1].hasSuffix(" requests") else { return nil }
        return Int(parts[1].dropLast(" requests".count).replacingOccurrences(of: ",", with: ""))
    }

    // "2026-09" → "Sep", "2026-09-24" → "09-24"
    static func bucketLabel(_ key: String) -> String {
        guard key.count == 7, let m = Int(key.suffix(2)), (1...12).contains(m) else { return String(key.suffix(5)) }
        return Calendar.current.shortMonthSymbols[m - 1]
    }

    static func short(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "%.0fk", Double(n) / 1e3)
        default: "\(n)"
        }
    }

    static func pct(_ n: Int, _ total: Int) -> String {
        guard total > 0 else { return "0%" }
        let p = Double(n) / Double(total) * 100
        return p < 1 && n > 0 ? "<1%" : "\(Int(p.rounded()))%"
    }
}

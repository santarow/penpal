import Charts
import SwiftUI

// Activity, all time or the last 30 or 7 days: what the Claude app's stats card shows, from
// bin/kite stats. Worked out from this Mac's transcripts (they can be deleted or edited), so it's
// labelled that way and never saved. Tokens are counted once per reply; the card's own way (once
// per line a reply is written on) is shown beside it, from the same scan, so the two tie out.
struct ActivityReport: Decodable {
    struct Model: Decodable { let input: Int; let output: Int; let claude: Int; var once: Int { input + output } }
    struct Day: Decodable { let messages: Int; let tokens: [String: Int] }
    let period: String
    let saved_until: String?
    let sessions, messages, active_days: Int
    let checks: Int?            // Kite's own /usage checks, saved as sessions before 2026-09-27
    let check_messages: Int?
    let peak_hour: Int?
    let tokens_once, tokens_claude, saved_tokens: Int
    let favorite: String?
    let models: [String: Model]
    let days: [String: Day]
    let ties_out: Bool
}

@MainActor
final class ActivityModel: ObservableObject {
    @Published var report: ActivityReport?
    @Published var loading = false
    @Published var pinned: String?    // the model picked in the table: the chart shows it on its own
    @Published var period = UserDefaults.standard.string(forKey: "activity.period") ?? "all" {
        didSet { UserDefaults.standard.set(period, forKey: "activity.period"); load() }
    }

    func load() {
        guard let root = Kite.root else { return }
        loading = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli)
        p.arguments = ["stats", period]
        var env = Kite.engineEnv
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let asked = period
        p.terminationHandler = { _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                self.loading = false
                guard asked == self.period else { return }
                if let r = try? JSONDecoder().decode(ActivityReport.self, from: data) { self.report = r }
            }
        }
        do { try p.run() } catch { loading = false }
    }
}

struct ActivitySection: View {
    @ObservedObject var model: ActivityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity").font(.title3.bold())
                Text("like Claude's stats card").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Picker("", selection: $model.period) {
                    Text("All").tag("all"); Text("30 days").tag("30"); Text("7 days").tag("7")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Label("Worked out from this Mac's transcripts, which can be deleted or edited, so it can't be checked against /usage. Not saved.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            if let r = model.report, r.period == model.period {
                content(r)
            } else {
                ProgressView("Reading your transcripts…").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if model.report == nil { model.load() } }
    }

    @ViewBuilder private func content(_ r: ActivityReport) -> some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                tile("Sessions", r.sessions.formatted(), help: "Yours, not counting \(AppName.shown)'s limit checks (see below)")
                tile("Messages", r.messages.formatted(), help: "Counted like Claude's card: every line in a transcript, yours and Claude's. One reply often takes 2 or more lines.")
                tile("Tokens", UsageView.short(r.tokens_once), help: "Input plus output, each reply counted once. Claude's card counts \(UsageView.short(r.tokens_claude)): see below.")
            }
            GridRow {
                tile("Active days", "\(r.active_days)")
                tile("Peak hour", r.peak_hour.map(Self.hour) ?? "–", help: "The hour most sessions started")
                tile("Favorite model", r.favorite.map(ModelName.pretty) ?? "–", help: "Most tokens, each reply counted once")
            }
        }
        if let c = r.checks, c > 0 {
            // A state that doesn't fit is its own row: the card counts these, so the numbers still tie out.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "equal.circle").foregroundStyle(.secondary)
                Text("Claude's card counts **\((r.sessions + c).formatted())** sessions: \(r.sessions.formatted()) yours + \(c.formatted()) of \(AppName.shown)'s own limit checks (0 tokens each, saved before Sep 27, when \(AppName.shown) stopped saving them). Messages leave out their \((r.check_messages ?? 0).formatted()) lines.")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        heatmap(r)
        // Why Claude's number is bigger: the same scan, counted its way.
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "equal.circle").foregroundStyle(.secondary)
            Text("Claude's card shows **\(UsageView.short(r.tokens_claude))** tokens here. It adds a reply's tokens once for every line the reply is written on (thinking, text and each tool use get their own line), so most replies count twice or more. \(AppName.shown) counts each reply once, the way that ties out with /usage.")
        }
        .font(.caption).foregroundStyle(.secondary)
        models(r)
        HStack {
            if let s = r.saved_until, r.period == "all" {
                Text("Up to \(s): Claude Code's own saved stats (its counting, \(UsageView.short(r.saved_tokens)) tokens).")
            }
            Spacer()
            Label(r.ties_out ? "Adds up" : "Doesn't add up: a bug", systemImage: r.ties_out ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(r.ties_out ? Color.secondary : Color.red)
                .help("Per model and per day, the tokens add back to the total")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func tile(_ label: String, _ value: String, help: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .help(help)
    }

    static func hour(_ h: Int) -> String {
        var c = DateComponents(); c.hour = h
        return Calendar.current.date(from: c)?.formatted(.dateTime.hour()) ?? "\(h):00"
    }

    // Weeks across, days down, like the card: darker = more messages that day.
    @ViewBuilder private func heatmap(_ r: ActivityReport) -> some View {
        let cal = Calendar.current
        let f = DateFormatter(); let _ = (f.dateFormat = "yyyy-MM-dd")
        let today = cal.startOfDay(for: Date())
        let first = r.days.keys.sorted().first.flatMap { f.date(from: $0) } ?? today
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let weeks = min(53, max(1, (cal.dateComponents([.day], from: first, to: thisWeek).day ?? 0) / 7 + 1))
        let start = cal.date(byAdding: .day, value: -(weeks - 1) * 7, to: thisWeek) ?? today
        let top = max(1, r.days.values.map(\.messages).max() ?? 1)
        HStack(spacing: 3) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: w * 7 + d, to: start) ?? today
                        let n = day > today ? -1 : r.days[f.string(from: day)]?.messages ?? 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(n < 0 ? Color.clear : n == 0 ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.3 + 0.7 * Double(n) / Double(top)))
                            .frame(width: 10, height: 10)
                            .help(n < 0 ? "" : "\(day.formatted(date: .abbreviated, time: .omitted)): \(max(n, 0)) messages")
                    }
                }
            }
        }
    }

    // Like Screen Time: two colors (current and previous models), totals under the chart, and a
    // model picked in the table shown on its own, in blue over everything else in gray.
    @ViewBuilder private func models(_ r: ActivityReport) -> some View {
        let current = Self.current(r)
        // Newest first: current models, then older versions down to the oldest (ties: most used first).
        let rows = r.models.filter { $0.value.once > 0 }.sorted { a, b in
            let ca = current.contains(a.key), cb = current.contains(b.key)
            if ca != cb { return ca }
            let va = Self.version(a.key), vb = Self.version(b.key)
            if va != vb { return vb.lexicographicallyPrecedes(va) }
            return a.value.once > b.value.once
        }
        // The table covers the same tokens as the chart: the saved days are their own row.
        let total = max(1, r.models.values.reduce(0) { $0 + $1.once } + r.saved_tokens)
        let focus = model.pinned
        let kinds = focus.map { [ModelName.pretty($0), "Everything else"] } ?? ["Current models", "Previous models"]
        let bars: [Bar] = r.days.sorted { $0.key < $1.key }.flatMap { day, v -> [Bar] in
            let all = v.tokens.values.reduce(0, +)
            let first = focus.map { v.tokens[$0] ?? 0 } ?? v.tokens.filter { current.contains($0.key) }.values.reduce(0, +)
            return [Bar(day: day, kind: kinds[0], n: first), Bar(day: day, kind: kinds[1], n: all - first)]
        }
        let firstTotal = bars.filter { $0.kind == kinds[0] }.reduce(0) { $0 + $1.n }
        let secondTotal = bars.filter { $0.kind == kinds[1] }.reduce(0) { $0 + $1.n }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(focus.map { ModelName.pretty($0) + " usage" } ?? "By day and model").font(.headline)
                Spacer()
                if focus != nil { Button("All models") { model.pinned = nil }.buttonStyle(.link) }
            }
            .padding(.top, 4)
            Chart(bars) { b in
                BarMark(x: .value("Day", b.day), y: .value("Tokens", b.n))
                    .foregroundStyle(by: .value("Kind", b.kind))
            }
            .chartForegroundStyleScale(domain: kinds, range: focus == nil ? [Color.blue, Color.teal] : [Color.blue, Color.gray.opacity(0.35)])
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks { v in AxisValueLabel { if let n = v.as(Int.self) { Text(UsageView.short(n)) } }; AxisGridLine() } }
            .frame(height: 140)
            HStack(alignment: .top, spacing: 28) {
                legendItem(kinds[0], firstTotal, .blue)
                legendItem(kinds[1], secondTotal, focus == nil ? .teal : .gray)
            }
            VStack(spacing: 0) {
                HStack {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("In").frame(width: 56, alignment: .trailing)
                    Text("Out").frame(width: 56, alignment: .trailing)
                    Text("Share").frame(width: 50, alignment: .trailing)
                    Text("Claude's count").frame(width: 96, alignment: .trailing)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
                row(name: "All models", input: rows.reduce(0) { $0 + $1.value.input }, output: rows.reduce(0) { $0 + $1.value.output },
                    share: "100%", claude: r.tokens_claude, selected: focus == nil) { model.pinned = nil }
                ForEach(rows, id: \.key) { m, v in
                    row(name: ModelName.pretty(m) + (current.contains(m) ? "" : " · previous"), input: v.input, output: v.output,
                        share: UsageView.pct(v.once, total), claude: v.claude, selected: focus == m) {
                        model.pinned = model.pinned == m ? nil : m
                    }
                }
                if r.saved_tokens > 0, let s = r.saved_until {
                    row(name: "Up to \(s), Claude's saved stats", input: nil, output: nil,
                        share: UsageView.pct(r.saved_tokens, total), claude: r.saved_tokens, selected: false) {}
                        .foregroundStyle(.secondary)
                        .help("Claude Code's stats-cache.json keeps in plus out per model, counted its way. It can't be split or re-counted")
                }
            }
            .font(.callout)
        }
    }

    struct Bar: Identifiable { let day: String; let kind: String; let n: Int; var id: String { day + kind } }

    private func legendItem(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(UsageView.short(n)).font(.callout.weight(.medium)).monospacedDigit()
        }
    }

    private func row(name: String, input: Int?, output: Int?, share: String, claude: Int, selected: Bool,
                     tap: @escaping () -> Void) -> some View {
        HStack {
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(input.map(UsageView.short) ?? "–").monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(output.map(UsageView.short) ?? "–").monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(share).monospacedDigit().frame(width: 50, alignment: .trailing)
            Text(UsageView.short(claude)).monospacedDigit().foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.secondary.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }

    // "claude-opus-5-5" → [5, 5]; "claude-haiku-4-5-20251001" → [4, 5] (the date isn't a version).
    static func version(_ id: String) -> [Int] {
        id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").dropFirst()
            .map(String.init).filter { $0.count <= 2 }.compactMap { Int($0) }
    }

    // The newest version in each family (Opus, Fable, Sonnet, Haiku) is current; older ones are previous.
    static func current(_ r: ActivityReport) -> Set<String> {
        var ids = Set(r.models.keys)
        for d in r.days.values { ids.formUnion(d.tokens.keys) }
        func parts(_ id: String) -> (String, [Int]) {
            let p = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
            return (p.first ?? id, p.dropFirst().filter { $0.count <= 2 }.compactMap { Int($0) })
        }
        var best: [String: [Int]] = [:]
        for id in ids {
            let (f, v) = parts(id)
            if let b = best[f], !b.lexicographicallyPrecedes(v) { continue }
            best[f] = v
        }
        return Set(ids.filter { let (f, v) = parts($0); return best[f] == v })
    }
}

// A model's id as people say it: claude-sonnet-5-5 → "Sonnet 5.5" (moved from VoiceAgent, #315: the Usage window is Penpal's too).
enum ModelName {
    static func pretty(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        guard let family = parts.first else { return id }
        let nums = parts.dropFirst().filter { $0.count <= 2 && Int($0) != nil }
        return family.prefix(1).uppercased() + family.dropFirst() + (nums.isEmpty ? "" : " " + nums.joined(separator: "."))
    }
}

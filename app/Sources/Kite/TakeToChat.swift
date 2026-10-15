import AppKit

// Take to Chat (#325, Jason: "a feature or button to summarize the current session and pass it to claude chat, so i can
// talk about the content while i drive"). The Claude Code session last in front in Claude's Code tab, its latest turns
// (keys and tokens taken out: bin/kite brief), made into a spoken briefing by your own Claude (agents/briefing), and
// sent as a new chat in Claude's Chat tab, so it's on your iPhone for voice mode.
@MainActor
enum TakeToChat {
    static let opener = "Let's talk through this Claude Code session by voice. Here's where it stands:"
    private static var busy = false

    static func start() {
        guard !busy else { return Notice.show("Already writing a briefing.") }
        guard let root = Kite.root else { return Notice.show("\(AppName.shown) can't find its engine.") }
        busy = true
        Notice.show("Writing a briefing of your Claude Code session…", seconds: 4)
        Log.line("chat: take to chat")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli)
            p.arguments = ["brief"]
            p.environment = Kite.engineEnv
            p.standardOutput = out; p.standardError = err
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile(), problem = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let text = d["text"] as? String else {
                    busy = false
                    let why = String(data: problem, encoding: .utf8)?.replacingOccurrences(of: "kite: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    Log.line("chat: no session (\(why))")
                    return Notice.show(why.isEmpty ? "Couldn't read a Claude Code session." : "Couldn't: \(why).", seconds: 5)
                }
                Log.line("chat: \(d["shown"] ?? 0) of \(d["turns"] ?? 0) turns of \"\((d["title"] as? String ?? "").prefix(40))\"")
                brief(text)
            } }
        }
    }

    private static func brief(_ session: String) {
        AgentStore.shared.runAgent("briefing", "Write the spoken briefing of this session.", context: session) { id in
            guard let id else { busy = false; return Notice.show("Couldn't start your Claude.") }
            RunState.watch(agent: "briefing", id: id) { run in
                guard run.status == "done", let b = run.result?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else {
                    busy = false
                    return Notice.show(run.plainProblem ?? "Your Claude didn't write the briefing. Try again.", seconds: 5)
                }
                Paster.startChat(opener + "\n\n" + b) { how in
                    busy = false
                    switch how {
                    case "sent": Notice.show("In a new Claude chat: open it on your iPhone and talk it through.", seconds: 5)
                    case "filled": Notice.show("It's in a new Claude chat: press Return to send it.", seconds: 5)
                    default: Notice.show("Copied the briefing: open a new chat in Claude and press ⌘V.", seconds: 5)
                    }
                }
            }
        }
    }
}

// --brief-check <out.txt> (#325): the briefing of the session in front, written to out.txt and checked; no chat is
// opened and nothing typed. Its length, and that it reads aloud (no lists, tables, code or links), and no key in it.
extension TakeToChat {
    static func check(out: String) {
        guard let root = Kite.root else { print("no engine"); exit(1) }
        func engine(_ args: [String]) -> String {
            let p = Process(), o = Pipe()
            p.executableURL = URL(fileURLWithPath: root + "/" + Kite.cli); p.arguments = args
            p.environment = Kite.engineEnv; p.standardOutput = o
            try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: d, encoding: .utf8) ?? ""
        }
        guard let d = (try? JSONSerialization.jsonObject(with: Data(engine(["brief"]).utf8))) as? [String: Any], let text = d["text"] as? String
        else { print("no session"); exit(1) }
        print("session: \(d["shown"] ?? 0) of \(d["turns"] ?? 0) turns, \(text.count) characters")
        let ctx = FileManager.default.temporaryDirectory.appendingPathComponent("penpal-brief-\(UUID().uuidString).md")
        try? text.write(to: ctx, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: ctx) }
        let started = Date.now
        let said = engine(["run", "briefing", "Write the spoken briefing of this session.", "--context", ctx.path])
        guard let name = said.split(separator: " ").first?.split(separator: "/").last.map(String.init) else { print("run: \(said)"); exit(1) }
        var result = ""
        while Date.now.timeIntervalSince(started) < 180 {
            if let s = RunState.read(agent: "briefing", id: name), s.status != "working" { result = s.result ?? ""; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let message = opener + "\n\n" + result.trimmingCharacters(in: .whitespacesAndNewlines)
        try? message.write(toFile: out, atomically: true, encoding: .utf8)
        let words = result.split(whereSeparator: \.isWhitespace).count
        var ok = true
        func check(_ what: String, _ pass: Bool) { print("\(pass ? "ok  " : "FAIL") \(what)"); if !pass { ok = false } }
        print("briefing: \(words) words in \(Int(Date.now.timeIntervalSince(started)))s")
        check("about 300 to 400 words", (250...450).contains(words))
        check("reads aloud: no lists, tables, headings, code or links",
              !result.contains("```") && !result.contains("|") && !result.contains("http") && !result.split(separator: "\n").contains { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("#") })
        check("covers what's open and what's next", result.lowercased().contains("open") && result.lowercased().contains("next"))
        check("no key or token in it", !result.contains("[removed]") && result.range(of: #"sk-ant-|ghp_|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\."#, options: .regularExpression) == nil)
        print(ok ? "all passed" : "SOME FAILED")
        exit(ok ? 0 : 1)
    }
}

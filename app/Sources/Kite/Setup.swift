import AppKit

// Workshop on someone else's Mac: it runs their own Claude Code, with Python (bin/kite) and uv
// (voice and some agent tools). On first launch of a release build, and whenever one is missing,
// it says what's missing and how to get it. It installs nothing itself; "Install" hands off to
// Apple's own installer, and the commands are copied for the user to run.
@MainActor
enum Setup {
    struct Need { let name: String; let why: String; let how: String }

    static func check() {
        guard Features.isRelease else { return }
        // Penpal's highlight and lenses need none of these (#245): only Commands, Usage, History and Guide me
        // run bin/kite and claude, and Penpal has no voice. So it asks only while one of those is on.
        let engine = Flavor.current != .penpal || [Feature.commands, .usage, .history, .guide].contains { Features.on($0) } || Enhance.available
        let voice = Flavor.current.has(.voice)
        DispatchQueue.global(qos: .utility).async {
            var missing: [Need] = []
            if engine, !found("claude") {
                missing.append(Need(name: "Claude Code", why: "\(AppName.shown) runs your own Claude",
                                    how: "curl -fsSL https://claude.ai/install.sh | bash"))
            }
            if engine, !appleTools() {
                missing.append(Need(name: "Apple's Command Line Tools (Python 3)", why: "\(AppName.shown)'s engine is a Python script",
                                    how: "xcode-select --install"))
            }
            let list = missing
            DispatchQueue.main.async { if !list.isEmpty { MainActor.assumeIsolated { show(list) } } }
        }
    }

    private static func show(_ missing: [Need]) {
        let a = NSAlert()
        let n = missing.count == 1 ? "one thing" : "\(missing.count) things"
        // Penpal works without them (#247): say which parts wait, not that the app can't start.
        let penpal = Flavor.current == .penpal
        a.messageText = penpal ? "Guide me, Enhance, Claude Commands and History need \(n) on this Mac" : "\(AppName.shown) needs \(n) on this Mac"
        a.informativeText = missing.map { "• \($0.name): \($0.why).\n   \($0.how)" }.joined(separator: "\n\n")
            + "\n\nRun the commands in Terminal, then reopen \(AppName.shown)."
            + (penpal ? " Highlight and snippets work now, without them." : "")
        let apple = missing.contains { $0.how == "xcode-select --install" }
        if apple { a.addButton(withTitle: "Install Apple's Tools") }
        a.addButton(withTitle: "Copy Commands")
        a.addButton(withTitle: "Later")
        let r = a.runModal()
        let copy: NSApplication.ModalResponse = apple ? .alertSecondButtonReturn : .alertFirstButtonReturn
        if apple && r == .alertFirstButtonReturn {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["--install"]
            try? p.run()
        } else if r == copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(missing.map(\.how).filter { $0 != "xcode-select --install" }.joined(separator: "\n"), forType: .string)
        }
    }

    // On the PATH Kite gives its helpers (~/.local/bin, Homebrew, /usr/local/bin, /usr/bin).
    nonisolated private static func found(_ tool: String) -> Bool {
        Kite.path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
    }
    // /usr/bin/python3 is only a stub until Apple's tools are installed; xcode-select -p says whether they are.
    nonisolated private static func appleTools() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// An app and its dev build are separate apps that share ~/.kite. Both running at once fight over the
// screenshot keys, so at launch the app says so and offers to quit one.
@MainActor
enum OtherBuild {
    static var names: [String: String] { Flavor.builds }

    static func check() {
        let me = Bundle.main.bundleIdentifier ?? ""
        guard let other = names.first(where: { $0.key != me }),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: other.key).first else { return }
        let a = NSAlert()
        a.messageText = "\(other.value) is also running"
        a.informativeText = "Two copies fight over the highlight keys, so neither works well. Keep one running."
        a.addButton(withTitle: "Quit \(other.value)")
        a.addButton(withTitle: "Quit \(AppName.shown)")
        a.addButton(withTitle: "Keep Both")
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: app.terminate()
        case .alertSecondButtonReturn: NSApp.terminate(nil)
        default: break
        }
    }
}

// Run from the mounted .dmg (or a quarantined copy macOS moved aside), Workshop can't keep its
// permissions or update well. Like most Mac apps, it offers to move itself to Applications.
@MainActor
enum MoveToApplications {
    static func check() {
        let path = Bundle.main.bundlePath
        guard Features.isRelease, path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return }
        let a = NSAlert()
        a.messageText = "Move \(AppName.shown) to Applications?"
        a.informativeText = "It's running from the disk image. In Applications it keeps its permissions and its place in Launchpad."
        a.addButton(withTitle: "Move to Applications"); a.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications/\(URL(fileURLWithPath: path).lastPathComponent)")
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }  // the old copy goes to the Trash
            try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
            Log.line("moved to \(dest.path)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", dest.path]
            try? p.run()
            NSApp.terminate(nil)
        } catch {
            let b = NSAlert()
            b.messageText = "Couldn't move it"
            b.informativeText = "Drag \(AppName.shown) from the disk image to the Applications folder, then open it from there. (\(error.localizedDescription))"
            b.runModal()
        }
    }
}

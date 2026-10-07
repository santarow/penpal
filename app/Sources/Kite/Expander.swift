import AppKit
import ApplicationServices

// 1.3: type ";cat" in the Claude app and it becomes the cat lens.
// Listens only while Claude is in front, keeps the last few characters in memory,
// and never presses Enter: you still send the message yourself.
@MainActor
final class Expander: ObservableObject {
    static let claudeApps: Set<String> = ["com.anthropic.claudefordesktop"]

    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published var enabled = true

    let lenses: LensStore
    private var buffer = ""
    private var monitor: Any?

    static private(set) weak var current: Expander?

    init(lenses: LensStore, live: Bool = true) {  // live: false for a picture of Settings (no key monitor)
        self.lenses = lenses
        guard live else { return }
        Expander.current = self
        Access.whenTrusted {
            self.trusted = true
            self.install()
        }
    }

    // Shows the system prompt that sends the user to Accessibility settings.
    func requestAccess() {
        let prompt = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, which Swift 6 rejects as a global var
        trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    private func install() {
        guard Flavor.current.has(.lenses) else { return }  // ;name expansion is Penpal's
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { self.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) {
        // Return in Claude sends the message: the next picture is 🖼 1 again. (Shift-Return is a new line.)
        if event.keyCode == 36, event.modifierFlags.isDisjoint(with: [.shift, .option, .command, .control]),
           let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.claudeApps.contains(front),
           UserDefaults.standard.double(forKey: "pictures.at") > 0 {
            Paster.resetPictures()
        }
        guard enabled, Features.on(.lenses),
              let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              Self.claudeApps.contains(app),
              event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        else { buffer = ""; return }

        if event.keyCode == 51 {  // delete
            if !buffer.isEmpty { buffer.removeLast() }
            return
        }
        // Return, tab, escape and arrow keys end the word.
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { buffer = ""; return }

        buffer = String((buffer + chars.lowercased()).suffix(32))
        // Each lens has an abbreviation of your choosing (default ";name"); case doesn't matter.
        if let hit = lenses.triggers().first(where: { !$0.abbrev.isEmpty && buffer.hasSuffix($0.abbrev.lowercased()) }) {
            buffer = ""
            expand(hit.name, typed: hit.abbrev.count)
        }
    }

    private func expand(_ name: String, typed: Int) {
        guard let text = lenses.expansion(name) else { return }
        Paster.paste(text, deleting: typed)  // the abbreviation you just typed
    }
}

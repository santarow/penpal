import AppKit

// Esc closes the Kite window in front (Settings, Usage, Commands, the chat window). The dock is
// a panel and stays; the capture and guide boxes handle Esc themselves.
@MainActor
enum Shortcuts {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let w = NSApp.keyWindow, w.styleMask.contains(.titled), w.styleMask.contains(.closable)
            else { return event }
            w.performClose(nil)
            return nil
        }
    }
}

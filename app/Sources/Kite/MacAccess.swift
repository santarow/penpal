import AppKit
import CoreServices
import EventKit

// Calendar and Mail access for the Chief agent. macOS grants these to Kite.app, and the
// agent's tools (mcp/mac.py, started by Kite through claude) inherit Kite's grant.
@MainActor
final class MacAccess: ObservableObject {
    static let shared = MacAccess()

    @Published private(set) var calendar = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var mailNote = ""

    var calendarAllowed: Bool { calendar == .fullAccess }
    var calendarLabel: String {
        switch calendar {
        case .fullAccess: "Allowed"
        case .denied: "Denied. Turn on \(AppName.shown) in System Settings → Privacy & Security → Calendars"
        case .restricted: "Restricted on this Mac"
        case .writeOnly: "Add-only. \(AppName.shown) needs full access to read events"
        default: "Not allowed yet"
        }
    }

    // Shows macOS's own prompt; the user decides.
    func requestCalendar() {
        if calendar == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return
        }
        EKEventStore().requestFullAccessToEvents { _, _ in
            Task { @MainActor in
                self.calendar = EKEventStore.authorizationStatus(for: .event)
                Log.line("calendar access: \(self.calendarLabel)")
            }
        }
    }

    // Asks Mail for its account count, which makes macOS show the Automation prompt once.
    func requestMail() {
        mailNote = "Asking…"
        DispatchQueue.global().async {
            var error: NSDictionary?
            let result = NSAppleScript(source: "tell application \"Mail\" to count of accounts")?.executeAndReturnError(&error)
            let note = result != nil ? "Allowed"
                : (error?[NSAppleScript.errorNumber] as? Int == -1743
                   ? "Denied. Turn on Mail under \(AppName.shown) in System Settings → Privacy & Security → Automation"
                   : "Couldn't reach Mail")
            Task { @MainActor in
                self.mailNote = note
                Log.line("mail access: \(note)")
            }
        }
    }

    var mailAllowed: Bool { mailNote == "Allowed" }

    // Checks both without asking: the Mail check never shows a prompt.
    func refresh() {
        calendar = EKEventStore.authorizationStatus(for: .event)
        var target = AEAddressDesc()
        let id = "com.apple.mail"
        _ = id.withCString { AECreateDesc(typeApplicationBundleID, $0, id.utf8.count, &target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        AEDisposeDesc(&target)
        switch status {
        case noErr: mailNote = "Allowed"
        case OSStatus(errAEEventNotPermitted): mailNote = "Denied. Turn on Mail under \(AppName.shown) in System Settings → Privacy & Security → Automation"
        default: break  // not asked yet, or Mail isn't running: leave as is
        }
    }
}

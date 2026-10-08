import AppKit
import Foundation

// Penpal's own source (#315): Penpal is the only app here, and it has every feature listed.
enum Flavor: String {
    case penpal

    nonisolated static let current = Flavor.penpal
    nonisolated static let isWorkshop = false
    nonisolated var name: String { "Penpal" }

    nonisolated static let penpalFeatures: Set<Feature> = [.capture, .lenses, .commands, .usage, .history, .sessions, .pin, .makeRoom, .guide]
    nonisolated func has(_ f: Feature) -> Bool { Self.penpalFeatures.contains(f) }

    // Penpal's data, its own bits too, live in its own folder (Kite.home: ~/Library/Application Support/Penpal, #310).
    nonisolated static var ownHome: URL { Kite.home }
    nonisolated static let feedbackAddress = "jason@santarow.com"
    nonisolated static let dockNudge = 0.0
    // The other build of Penpal, which mustn't run at the same time.
    nonisolated static let builds = ["dev.santarow.penpal": "Penpal Dev", "com.santarow.penpal": "Penpal"]
}

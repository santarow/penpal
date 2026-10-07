import Foundation

// Features that exist but aren't the point yet. Off by default; Settings → Labs turns them on.
// Everything they made (topics, runs) stays on disk while they're off.
enum Labs {
    @MainActor static var topics: Bool { Features.on(.missions) }  // now a feature switch (Settings → Features)
    static var circleAsk: Bool { UserDefaults.standard.bool(forKey: "labs.circleAsk") }
    static var chief: Bool { UserDefaults.standard.bool(forKey: "labs.chief") }  // Calendar and Mail tools, Settings section
}

import Foundation

// The app's own log, plain text: ~/Library/Logs/Kite/kite.log (Workshop), ~/Library/Logs/<App>/<app>.log.
// KITE_LOG for a test run, so it never writes into the log of the app in use (other sessions read it).
// Steps and timings only: never screen, clipboard or message contents.
enum Log {
    static let url = ProcessInfo.processInfo.environment["KITE_LOG"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(Flavor.isWorkshop == false ? "Library/Logs/\(Flavor.current.name)/\(Flavor.current.rawValue).log" : "Library/Logs/Kite/kite.log")

    static func line(_ text: String) {
        let stamp = Date.now.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))", timeZone: .current, calendar: .current))
        let data = Data("\(stamp) \(text)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

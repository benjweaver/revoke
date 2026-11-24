import Foundation

/// Access the person gave for a while, after an app asked: when each one ends, by
/// bundle ID. The network filter keeps the times and takes the access back itself;
/// this is the panel's copy, so a switch that's on for now doesn't look like one
/// that's simply on.
struct Allowances: Equatable, Sendable {
    /// Blocked apps let onto the local network for now.
    var localNetwork: [String: Date] = [:]
    /// Limited apps given the whole internet for now.
    var internet: [String: Date] = [:]

    var isEmpty: Bool { localNetwork.isEmpty && internet.isEmpty }

    /// The first one to end, which is when the panel has to look again.
    var nextEnd: Date? { (Array(localNetwork.values) + Array(internet.values)).min() }

    /// Without the ones that have ended.
    func inForce(at now: Date) -> Allowances {
        Allowances(localNetwork: localNetwork.filter { $0.value > now }, internet: internet.filter { $0.value > now })
    }

    /// What to show after asking the filter again: its answer, or, when it didn't
    /// answer, what it said before. A filter that's restarting misses a question, and
    /// the access it gave for a while is still on, so the panel goes on saying so.
    func replaced(by answer: Allowances?, at now: Date) -> Allowances {
        (answer ?? self).inForce(at: now)
    }

    /// Whole minutes left, rounded up so the last minute reads "1" and never "0".
    static func minutesLeft(until end: Date, now: Date) -> Int {
        max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// The time left, short enough to sit inside a switch: "38m", then "1h33" from an
    /// hour up, so it reads the same way as "1 hour 33 minutes" in the list above the
    /// grid. The exact end time is in that list and the tooltip.
    static func compact(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(rest < 10 ? "0" : "")\(rest)"
    }

    /// One short sentence for the panel's title line and the menu bar lock, from the
    /// names of the watched apps each thing is true of. "Locked down" is only said
    /// when nothing is on for now either: the panel lists that access right under
    /// this line, and the two read as a contradiction. It's here, apart from the
    /// model, so the tests can reach it.
    static func status(canReadTCC: Bool, exposed: [String], running: [String], onForNow: [String]) -> String {
        guard canReadTCC else { return "Needs Full Disk Access to show status" }
        if !exposed.isEmpty {
            return "\(exposed.formatted(.list(type: .and))) \(exposed.count == 1 ? "has" : "have") access"
        }
        let running = Set(running).sorted()
        if !running.isEmpty { return "\(running.formatted(.list(type: .and))) \(running.count == 1 ? "is" : "are") running" }
        let onForNow = Set(onForNow).sorted()
        if !onForNow.isEmpty {
            return "\(onForNow.formatted(.list(type: .and))) \(onForNow.count == 1 ? "has" : "have") access for now"
        }
        return "Watched apps are locked down"
    }

    /// "38 minutes", "1 minute", "2 hours 5 minutes".
    static func spoken(minutes: Int) -> String {
        let (hours, rest) = (minutes / 60, minutes % 60)
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if rest > 0 || hours == 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return parts.joined(separator: " ")
    }
}

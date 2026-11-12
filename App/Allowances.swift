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

    /// Whole minutes left, rounded up so the last minute reads "1" and never "0".
    static func minutesLeft(until end: Date, now: Date) -> Int {
        max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// The time left, short enough to sit inside a switch: "38m", or "2h" from 100
    /// minutes up. The exact end time is in the row's note and the tooltip.
    static func compact(minutes: Int) -> String {
        minutes < 100 ? "\(minutes)m" : "\(Int((Double(minutes) / 60).rounded()))h"
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

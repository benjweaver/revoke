import Foundation
import Testing

/// The revoke://request links apps open to ask for access: what they can ask for, and
/// what Revoke makes of a link that isn't well formed.
struct AccessRequestTests {
    private func request(_ link: String) -> AccessRequest? {
        URL(string: link).flatMap(AccessRequest.init(url:))
    }

    @Test func readsWhatIsAskedFor() {
        let asked = request("revoke://request?access=local-network&minutes=30&reason=Reach%20the%20test%20VM")
        #expect(asked?.pane == .localNetwork)
        #expect(asked?.minutes == 30)
        #expect(asked?.reason == "Reach the test VM")
        #expect(asked?.claimedApp == nil)
        #expect(request("REVOKE://Request?access=Screen-Recording")?.pane == .screenRecording)
        #expect(request("revoke://request?access=accessibility")?.pane == .deviceControl)
    }

    @Test func canAskForTheWholeInternet() {
        let asked = request("revoke://request?access=internet&minutes=10&reason=Push%20the%20branch")
        #expect(asked?.what == .internet)
        #expect(asked?.pane == nil)
        #expect(asked?.minutes == 10)
    }

    @Test func keepsTheTimeWithinBounds() {
        #expect(request("revoke://request?access=local-network")?.minutes == AccessRequest.defaultMinutes)
        #expect(request("revoke://request?access=local-network&minutes=0")?.minutes == 1)
        #expect(request("revoke://request?access=local-network&minutes=-5")?.minutes == 1)
        #expect(request("revoke://request?access=local-network&minutes=100000")?.minutes == AccessRequest.maxMinutes)
        #expect(request("revoke://request?access=local-network&minutes=soon")?.minutes == AccessRequest.defaultMinutes)
    }

    @Test func turnsDownWhatItCannotBeAskedFor() {
        // Links and Running aren't an app's to switch on for itself.
        #expect(request("revoke://request?access=links") == nil)
        #expect(request("revoke://request?access=running") == nil)
        #expect(request("revoke://request?access=everything") == nil)
        #expect(request("revoke://request") == nil)
        #expect(request("revoke://grant?access=local-network") == nil)
        #expect(request("https://request?access=local-network") == nil)
        #expect(!AccessRequest.names.values.contains(.pane(.links)))
        #expect(!AccessRequest.names.values.contains(.pane(.running)))
    }

    @Test func theFirstOfARepeatedNameCounts() {
        let asked = request("revoke://request?access=local-network&minutes=5&minutes=240&access=full-disk-access")
        #expect(asked?.pane == .localNetwork)
        #expect(asked?.minutes == 5)
    }

    @Test func cutsALongReasonAndDropsAnEmptyOne() {
        let long = String(repeating: "a", count: AccessRequest.reasonLimit + 50)
        #expect(request("revoke://request?access=local-network&reason=\(long)")?.reason?.count == AccessRequest.reasonLimit)
        #expect(request("revoke://request?access=local-network&reason=%20%20")?.reason == nil)
    }

    @Test func onlyTakesAnAppThatLooksLikeABundleID() {
        #expect(request("revoke://request?access=local-network&app=com.example.agent")?.claimedApp == "com.example.agent")
        #expect(request("revoke://request?access=local-network&app=%2Fusr%2Fbin%2Fcurl")?.claimedApp == nil)
        #expect(request("revoke://request?access=local-network&app=agent")?.claimedApp == nil)
        #expect(request("revoke://request?access=local-network&app=com.example.a%20b")?.claimedApp == nil)
    }
}

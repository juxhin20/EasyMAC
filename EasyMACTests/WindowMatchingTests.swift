import XCTest

final class WindowMatchingTests: XCTestCase {
    let code = "com.microsoft.VSCode"
    let chrome = "com.google.Chrome"

    func testTitleHintWins() {
        let candidates = [
            MatchCandidate(windowID: 1, bundleID: code, title: "main.swift — EasyMAC — Visual Studio Code"),
            MatchCandidate(windowID: 2, bundleID: code, title: "index.php — RentalX — Visual Studio Code"),
        ]
        let result = WindowMatcher.assign([MatchRequest(bundleID: code, titleContains: "rentalx")], candidates: candidates)
        XCTAssertEqual(result[0], 2)
    }

    func testFallsBackToFirstUnassignedWindow() {
        let candidates = [
            MatchCandidate(windowID: 10, bundleID: chrome, title: "Gmail"),
            MatchCandidate(windowID: 11, bundleID: chrome, title: "GitHub"),
        ]
        let requests = [
            MatchRequest(bundleID: chrome, titleContains: nil),
            MatchRequest(bundleID: chrome, titleContains: nil),
            MatchRequest(bundleID: chrome, titleContains: nil),
        ]
        let result = WindowMatcher.assign(requests, candidates: candidates)
        XCTAssertEqual(result[0], 10)
        XCTAssertEqual(result[1], 11)
        XCTAssertNil(result[2], "never assigns the same window twice")
    }

    func testHintedRequestsAreServedBeforeUnhinted() {
        let candidates = [
            MatchCandidate(windowID: 1, bundleID: code, title: "RentalX"),
            MatchCandidate(windowID: 2, bundleID: code, title: "DTIS"),
        ]
        let requests = [
            MatchRequest(bundleID: code, titleContains: nil),
            MatchRequest(bundleID: code, titleContains: "RentalX"),
        ]
        let result = WindowMatcher.assign(requests, candidates: candidates)
        XCTAssertEqual(result[1], 1)
        XCTAssertEqual(result[0], 2)
    }

    func testHintWithoutMatchStillGetsAWindow() {
        let candidates = [MatchCandidate(windowID: 7, bundleID: code, title: "Welcome")]
        let result = WindowMatcher.assign([MatchRequest(bundleID: code, titleContains: "RentalX")], candidates: candidates)
        XCTAssertEqual(result[0], 7)
    }

    func testOtherAppsAreIgnored() {
        let candidates = [MatchCandidate(windowID: 1, bundleID: chrome, title: "RentalX")]
        XCTAssertTrue(WindowMatcher.assign([MatchRequest(bundleID: code, titleContains: "RentalX")], candidates: candidates).isEmpty)
    }

    func testBlankHintIsIgnored() {
        let candidates = [MatchCandidate(windowID: 3, bundleID: code, title: "x")]
        XCTAssertEqual(WindowMatcher.assign([MatchRequest(bundleID: code, titleContains: "   ")], candidates: candidates)[0], 3)
    }

    func testSuggestHint() {
        XCTAssertEqual(WindowMatcher.suggestHint(title: "index.php — RentalX — Visual Studio Code", appName: "Code"), "RentalX")
        XCTAssertEqual(WindowMatcher.suggestHint(title: "Inbox - Gmail - Google Chrome", appName: "Google Chrome"), "Gmail")
        XCTAssertNil(WindowMatcher.suggestHint(title: "Google Chrome", appName: "Google Chrome"))
        XCTAssertNil(WindowMatcher.suggestHint(title: "", appName: "Terminal"))
    }
}

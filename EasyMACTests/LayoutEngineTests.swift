import XCTest

final class LayoutEngineTests: XCTestCase {
    let area = CGRect(x: 0, y: 25, width: 1600, height: 1000)

    private func assertInside(_ rects: [CGRect], _ area: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for r in rects {
            XCTAssertTrue(area.contains(r), "\(r) escapes \(area)", file: file, line: line)
        }
    }

    private func assertNoOverlap(_ rects: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(rects[i].insetBy(dx: 1, dy: 1).intersects(rects[j]), "\(rects[i]) overlaps \(rects[j])", file: file, line: line)
            }
        }
    }

    func testEveryPresetReturnsOneFramePerWindow() {
        for preset in LayoutPreset.allCases {
            for count in 1...7 {
                let frames = LayoutEngine.frames(for: preset, count: count, in: area, gap: 8)
                XCTAssertEqual(frames.count, count, "\(preset) × \(count)")
                assertInside(frames, area)
                if preset != .maximize { assertNoOverlap(frames) }
            }
        }
    }

    func testZeroWindowsOrEmptyArea() {
        XCTAssertTrue(LayoutEngine.frames(for: .grid, count: 0, in: area).isEmpty)
        XCTAssertTrue(LayoutEngine.frames(for: .grid, count: 3, in: .zero).isEmpty)
    }

    func testHalvesTwoWindows() {
        let f = LayoutEngine.frames(for: .halves, count: 2, in: area, gap: 8)
        XCTAssertEqual(f[0], CGRect(x: 8, y: 33, width: 788, height: 984))
        XCTAssertEqual(f[1], CGRect(x: 804, y: 33, width: 788, height: 984))
    }

    func testHalvesThreeWindowsStacksRightColumn() {
        let f = LayoutEngine.frames(for: .halves, count: 3, in: area, gap: 0)
        XCTAssertEqual(f[0], CGRect(x: 0, y: 25, width: 800, height: 1000))
        XCTAssertEqual(f[1], CGRect(x: 800, y: 25, width: 800, height: 500))
        XCTAssertEqual(f[2], CGRect(x: 800, y: 525, width: 800, height: 500))
    }

    func testSixtyForty() {
        let f = LayoutEngine.frames(for: .sixtyForty, count: 2, in: area, gap: 0)
        XCTAssertEqual(f[0].width, 960)
        XCTAssertEqual(f[1].width, 640)
    }

    func testMainStackKeepsMainAlone() {
        let f = LayoutEngine.frames(for: .mainStack, count: 4, in: area, gap: 0)
        XCTAssertEqual(f[0], CGRect(x: 0, y: 25, width: 960, height: 1000))
        XCTAssertEqual(f[1...].map(\.minX), [960, 960, 960])
        XCTAssertEqual(f[1...].map(\.height).reduce(0, +), 1000, accuracy: 2)
    }

    func testThirdsWithTwoWindowsFallsBackToHalves() {
        let f = LayoutEngine.frames(for: .thirds, count: 2, in: area, gap: 0)
        XCTAssertEqual(f.map(\.width), [800, 800])
    }

    func testGridFiveWindows() {
        let f = LayoutEngine.frames(for: .grid, count: 5, in: area, gap: 0)
        // 3 columns × 2 rows, last row has 2 wider cells.
        XCTAssertEqual(f[0].height, 500)
        XCTAssertEqual(f[3].width, 800)
    }

    func testSnapHalvesAndQuarters() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(LayoutEngine.snap(.leftHalf, in: a, gap: 0), CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(LayoutEngine.snap(.rightHalf, in: a, gap: 0), CGRect(x: 500, y: 0, width: 500, height: 800))
        XCTAssertEqual(LayoutEngine.snap(.topHalf, in: a, gap: 0), CGRect(x: 0, y: 0, width: 1000, height: 400))
        XCTAssertEqual(LayoutEngine.snap(.bottomHalf, in: a, gap: 0), CGRect(x: 0, y: 400, width: 1000, height: 400))
        XCTAssertEqual(LayoutEngine.snap(.bottomRight, in: a, gap: 0), CGRect(x: 500, y: 400, width: 500, height: 400))
        XCTAssertEqual(LayoutEngine.snap(.maximize, in: a, gap: 10), CGRect(x: 10, y: 10, width: 980, height: 780))
    }

    func testSnapCenterKeepsSize() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = LayoutEngine.snap(.center, in: a, gap: 0, current: CGRect(x: 3, y: 4, width: 400, height: 300))
        XCTAssertEqual(f, CGRect(x: 300, y: 250, width: 400, height: 300))
    }

    func testCycling() {
        let a = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let half = LayoutEngine.snap(.leftHalf, in: a, gap: 0)
        XCTAssertEqual(LayoutEngine.cycled(.leftHalf, current: half, in: a, gap: 0), .leftTwoThirds)
        let twoThirds = LayoutEngine.snap(.leftTwoThirds, in: a, gap: 0)
        XCTAssertEqual(LayoutEngine.cycled(.leftHalf, current: twoThirds, in: a, gap: 0), .leftThird)
        XCTAssertEqual(LayoutEngine.cycled(.leftHalf, current: CGRect(x: 50, y: 50, width: 10, height: 10), in: a, gap: 0), .leftHalf)
        XCTAssertEqual(LayoutEngine.cycled(.topHalf, current: half, in: a, gap: 0), .topHalf)
    }

    func testRadialDirections() {
        XCTAssertEqual(LayoutEngine.radialDirection(dx: 3, dy: 2), .center)
        XCTAssertEqual(LayoutEngine.radialDirection(dx: 100, dy: 5), .right)
        XCTAssertEqual(LayoutEngine.radialDirection(dx: -100, dy: 5), .left)
        XCTAssertEqual(LayoutEngine.radialDirection(dx: 0, dy: 100), .top)
        XCTAssertEqual(LayoutEngine.radialDirection(dx: 0, dy: -100), .bottom)
        XCTAssertEqual(LayoutEngine.radialDirection(dx: 70, dy: 70), .topRight)
        XCTAssertEqual(LayoutEngine.radialDirection(dx: -70, dy: -70), .bottomLeft)
        XCTAssertEqual(LayoutEngine.radialDirection(dx: 100, dy: -30), .right)
        XCTAssertEqual(LayoutEngine.radialDirection(dx: 100, dy: -60), .bottomRight)
    }

    func testRadialSnapActions() {
        XCTAssertNil(RadialDirection.center.snapAction)
        XCTAssertEqual(RadialDirection.topLeft.snapAction, .topLeft)
        XCTAssertEqual(RadialDirection.bottom.snapAction, .bottomHalf)
    }
}

final class CoordinateTests: XCTestCase {
    func testRoundTrip() {
        let primaryHeight: CGFloat = 1117
        let ax = CGRect(x: 100, y: 40, width: 800, height: 600)
        let appKit = Coordinates.axToAppKit(ax, primaryHeight: primaryHeight)
        XCTAssertEqual(appKit, CGRect(x: 100, y: 477, width: 800, height: 600))
        XCTAssertEqual(Coordinates.appKitToAX(appKit, primaryHeight: primaryHeight), ax)
    }

    func testSecondaryDisplayAbovePrimary() {
        // A display stacked above the primary has negative AX y and AppKit y above primaryHeight.
        let appKit = CGRect(x: 0, y: 1117, width: 1920, height: 1080)
        XCTAssertEqual(Coordinates.appKitToAX(appKit, primaryHeight: 1117).minY, -1080)
    }

    func testPointConversion() {
        XCTAssertEqual(Coordinates.appKitToAX(CGPoint(x: 5, y: 100), primaryHeight: 900), CGPoint(x: 5, y: 800))
        XCTAssertEqual(Coordinates.axToAppKit(CGPoint(x: 5, y: 800), primaryHeight: 900), CGPoint(x: 5, y: 100))
    }

    func testRelativeAbsoluteRoundTrip() {
        let screen = CGRect(x: 1440, y: 25, width: 2560, height: 1415)
        let frame = CGRect(x: 1440 + 640, y: 25 + 100, width: 1280, height: 707)
        let rel = Coordinates.relative(frame, in: screen)
        XCTAssertEqual(rel.minX, 0.25, accuracy: 0.0001)
        XCTAssertEqual(Coordinates.absolute(rel, in: screen), frame.integral)
    }

    func testRelativeFrameSurvivesResolutionChange() {
        let rel = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        XCTAssertEqual(Coordinates.absolute(rel, in: CGRect(x: 0, y: 0, width: 1000, height: 600)), CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertEqual(Coordinates.absolute(rel, in: CGRect(x: 0, y: 0, width: 3000, height: 1600)), CGRect(x: 1500, y: 0, width: 1500, height: 1600))
    }

    func testClampKeepsWindowOnScreen() {
        let r = Coordinates.clampUnit(CGRect(x: 0.9, y: -0.2, width: 0.5, height: 1.4))
        XCTAssertEqual(r, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }
}
